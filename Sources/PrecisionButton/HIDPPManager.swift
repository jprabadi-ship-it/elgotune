import Foundation
import IOKit.hid

struct HIDPPPacket {
    static let softwareID: UInt8 = 0x0D
    static let longReportID: UInt8 = 0x11

    let bytes: [UInt8]

    var deviceIndex: UInt8 { bytes.count > 1 ? bytes[1] : 0 }
    var featureIndex: UInt8 { bytes.count > 2 ? bytes[2] : 0 }
    var function: UInt8 { bytes.count > 3 ? bytes[3] >> 4 : 0 }
    var softwareID: UInt8 { bytes.count > 3 ? bytes[3] & 0x0F : 0 }
    var parameters: ArraySlice<UInt8> { bytes.dropFirst(4) }
    var isError: Bool { featureIndex == 0x8F }

    static func request(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, parameters: [UInt8] = []) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 20)
        result[0] = longReportID
        result[1] = deviceIndex
        result[2] = featureIndex
        result[3] = (function << 4) | softwareID
        for (offset, byte) in parameters.prefix(16).enumerated() {
            result[4 + offset] = byte
        }
        return result
    }

    static func rootFeatureRequest(deviceIndex: UInt8, featureID: UInt16) -> [UInt8] {
        request(
            deviceIndex: deviceIndex,
            featureIndex: 0,
            function: 0,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )
    }
}

private final class HIDConnection: @unchecked Sendable {
    let device: IOHIDDevice
    let id: String
    let product: String
    let transport: String
    let candidateIndices: [UInt8]
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init(device: IOHIDDevice, id: String, product: String, transport: String, candidateIndices: [UInt8]) {
        self.device = device
        self.id = id
        self.product = product
        self.transport = transport
        self.candidateIndices = candidateIndices
        buffer.initialize(repeating: 0, count: 64)
    }

    deinit {
        buffer.deinitialize(count: 64)
        buffer.deallocate()
    }
}

private struct EndpointKey: Hashable {
    let connectionID: String
    let deviceIndex: UInt8
}

private struct EndpointState {
    var buttonFeatureIndex: UInt8
    var count: Int?
    var controls: [HIDPPControl] = []
    var pressed: Set<UInt16> = []
    var batteryFeatureID: UInt16?
    var batteryFeatureIndex: UInt8?
    var unifiedBatteryHasPercentage = false
    var battery: LogitechBattery?
}

private enum HIDPPFeature: UInt16 {
    case buttons = 0x1B04
    case unifiedBattery = 0x1004
    case batteryLevel = 0x1000
    case batteryVoltage = 0x1001
}

final class HIDPPManager: NSObject, @unchecked Sendable {
    var onDevicesChanged: (([LogitechDevice]) -> Void)?
    var onButton: ((ButtonSource, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var connections: [String: HIDConnection] = [:]
    private var endpoints: [EndpointKey: EndpointState] = [:]
    private var pendingRootFeatures: [EndpointKey: HIDPPFeature] = [:]
    private var diversionEnabled = true
    private var started = false

    func start(diversionEnabled: Bool) {
        guard !started else { return }
        started = true
        self.diversionEnabled = diversionEnabled

        let matching = [kIOHIDVendorIDKey as String: 0x046D] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceAdded, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log(result == kIOReturnSuccess ? "Logitech HIDの監視を開始" : "HID監視を開始できません (0x\(String(UInt32(bitPattern: result), radix: 16)))")
    }

    func rescan() {
        for source in pressedSources(in: endpoints.values.flatMap(\.pressed)) { onButton?(source, false) }
        endpoints.removeAll()
        pendingRootFeatures.removeAll()
        publishDevices()
        log("HID++デバイスを再スキャン")
        for connection in connections.values { probe(connection) }
    }

    func setDiversionEnabled(_ enabled: Bool) {
        diversionEnabled = enabled
        for (key, state) in endpoints {
            guard let connection = connections[key.connectionID] else { continue }
            for control in state.controls where sourceForControl(control.id) != nil && control.isDivertable {
                setDiversion(connection: connection, deviceIndex: key.deviceIndex, featureIndex: state.buttonFeatureIndex, controlID: control.id, enabled: enabled)
            }
        }
        log(enabled ? "ボタンのカスタマイズを有効化" : "ボタンを標準動作に復帰")
    }

    func refreshBattery() {
        for (key, state) in endpoints {
            guard let connection = connections[key.connectionID] else { continue }
            if state.batteryFeatureIndex == nil {
                requestRootFeature(.unifiedBattery, connection: connection, deviceIndex: key.deviceIndex)
            } else {
                requestBatteryStatus(connection: connection, key: key, state: state)
            }
        }
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        let product = stringProperty(device, key: kIOHIDProductKey as CFString) ?? "Logitech HID Device"
        let transport = stringProperty(device, key: kIOHIDTransportKey as CFString) ?? "Unknown"
        let usagePage = intProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let maxOutput = intProperty(device, key: kIOHIDMaxOutputReportSizeKey as CFString) ?? 0

        // HID++ interfaces expose vendor page 0xFF00 and long (20-byte) reports.
        guard maxOutput >= 20 || usagePage >= 0xFF00 else { return }

        let location = intProperty(device, key: kIOHIDLocationIDKey as CFString) ?? 0
        let productID = intProperty(device, key: kIOHIDProductIDKey as CFString) ?? 0
        let id = "\(location)-\(productID)-\(usagePage)"
        guard connections[id] == nil else { return }

        let isReceiver = product.localizedCaseInsensitiveContains("receiver")
        let indices = isReceiver ? Array(UInt8(1)...UInt8(6)) : [UInt8(0xFF)]
        let connection = HIDConnection(device: device, id: id, product: product, transport: transport, candidateIndices: indices)
        connections[id] = connection

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, connection.buffer, 64, hidInputReport, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            log("\(product)を開けません。Logi Options+を終了して再スキャンしてください")
            return
        }
        log("\(product)（\(transport)）を検出")
        probe(connection)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        guard let entry = connections.first(where: { $0.value.device === device }) else { return }
        let removedPressed = endpoints.filter { $0.key.connectionID == entry.key }.values.flatMap(\.pressed)
        for source in pressedSources(in: removedPressed) {
            onButton?(source, false)
        }
        connections.removeValue(forKey: entry.key)
        endpoints = endpoints.filter { $0.key.connectionID != entry.key }
        pendingRootFeatures = pendingRootFeatures.filter { $0.key.connectionID != entry.key }
        publishDevices()
        log("\(entry.value.product)が切断されました")
    }

    fileprivate func received(_ bytes: [UInt8], from device: IOHIDDevice) {
        guard let connection = connections.values.first(where: { $0.device === device }), bytes.count >= 7 else { return }
        let packet = HIDPPPacket(bytes: bytes)
        guard packet.bytes[0] == 0x10 || packet.bytes[0] == 0x11 else { return }
        if packet.isError { return }

        let key = EndpointKey(connectionID: connection.id, deviceIndex: packet.deviceIndex)

        if packet.featureIndex == 0, packet.function == 0, packet.softwareID == HIDPPPacket.softwareID {
            guard bytes.count > 4, let requestedFeature = pendingRootFeatures.removeValue(forKey: key) else { return }
            let featureIndex = bytes[4]
            if requestedFeature == .buttons {
                guard featureIndex != 0 else { return }
                endpoints[key] = EndpointState(buttonFeatureIndex: featureIndex)
                log("HID++スロット\(packet.deviceIndex): ボタン機能を検出")
                send(connection, HIDPPPacket.request(deviceIndex: packet.deviceIndex, featureIndex: featureIndex, function: 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.requestRootFeature(.unifiedBattery, connection: connection, deviceIndex: packet.deviceIndex)
                }
                return
            }

            guard var state = endpoints[key] else { return }
            guard featureIndex != 0 else {
                requestNextBatteryFeature(after: requestedFeature, connection: connection, deviceIndex: packet.deviceIndex)
                return
            }
            state.batteryFeatureID = requestedFeature.rawValue
            state.batteryFeatureIndex = featureIndex
            endpoints[key] = state
            log("HID++スロット\(packet.deviceIndex): バッテリー機能 0x\(String(requestedFeature.rawValue, radix: 16).uppercased()) を検出")
            requestBatteryStatus(connection: connection, key: key, state: state)
            return
        }

        guard var state = endpoints[key] else { return }

        if packet.featureIndex == state.batteryFeatureIndex,
           handleBatteryPacket(packet, connection: connection, key: key, state: &state) {
            return
        }

        guard packet.featureIndex == state.buttonFeatureIndex else { return }

        if packet.softwareID == HIDPPPacket.softwareID, packet.function == 0 {
            let count = Int(bytes[4])
            state.count = count
            endpoints[key] = state
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.025) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.send(connection, HIDPPPacket.request(deviceIndex: packet.deviceIndex, featureIndex: state.buttonFeatureIndex, function: 1, parameters: [UInt8(index)]))
                }
            }
            return
        }

        if packet.softwareID == HIDPPPacket.softwareID, packet.function == 1, bytes.count >= 9 {
            let cid = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let control = HIDPPControl(id: cid, flags: bytes[8])
            if !state.controls.contains(where: { $0.id == cid }) { state.controls.append(control) }
            endpoints[key] = state
            if let source = sourceForControl(cid) {
                log("\(source.displayName)を検出（CID 0x\(String(cid, radix: 16).uppercased())）")
                if diversionEnabled && control.isDivertable {
                    setDiversion(connection: connection, deviceIndex: packet.deviceIndex, featureIndex: state.buttonFeatureIndex, controlID: cid, enabled: true)
                }
                if source == .precision { publishDevices() }
            }
            return
        }

        // Event 0 reports the complete set of currently pressed diverted controls.
        if packet.softwareID != HIDPPPacket.softwareID, packet.function == 0 {
            var nowPressed = Set<UInt16>()
            for offset in stride(from: 4, through: min(bytes.count - 2, 10), by: 2) {
                let cid = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                if cid != 0 { nowPressed.insert(cid) }
            }
            let before = pressedSources(in: state.pressed)
            let after = pressedSources(in: nowPressed)
            state.pressed = nowPressed
            endpoints[key] = state
            for source in after.subtracting(before) { onButton?(source, true) }
            for source in before.subtracting(after) { onButton?(source, false) }
        }
    }

    private func probe(_ connection: HIDConnection) {
        for (offset, deviceIndex) in connection.candidateIndices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(offset) * 0.08) { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.requestRootFeature(.buttons, connection: connection, deviceIndex: deviceIndex)
            }
        }
    }

    private func requestRootFeature(_ feature: HIDPPFeature, connection: HIDConnection, deviceIndex: UInt8) {
        let key = EndpointKey(connectionID: connection.id, deviceIndex: deviceIndex)
        guard pendingRootFeatures[key] == nil else { return }
        pendingRootFeatures[key] = feature
        send(connection, HIDPPPacket.rootFeatureRequest(deviceIndex: deviceIndex, featureID: feature.rawValue))
    }

    private func requestNextBatteryFeature(after feature: HIDPPFeature, connection: HIDConnection, deviceIndex: UInt8) {
        switch feature {
        case .unifiedBattery:
            requestRootFeature(.batteryLevel, connection: connection, deviceIndex: deviceIndex)
        case .batteryLevel:
            requestRootFeature(.batteryVoltage, connection: connection, deviceIndex: deviceIndex)
        case .batteryVoltage:
            log("HID++スロット\(deviceIndex): バッテリー情報は非対応")
        case .buttons:
            break
        }
    }

    private func requestBatteryStatus(connection: HIDConnection, key: EndpointKey, state: EndpointState) {
        guard let featureID = state.batteryFeatureID,
              let feature = HIDPPFeature(rawValue: featureID),
              let featureIndex = state.batteryFeatureIndex else { return }
        let function: UInt8 = feature == .unifiedBattery && state.unifiedBatteryHasPercentage ? 1 : 0
        send(connection, HIDPPPacket.request(deviceIndex: key.deviceIndex, featureIndex: featureIndex, function: function))
    }

    private func handleBatteryPacket(
        _ packet: HIDPPPacket,
        connection: HIDConnection,
        key: EndpointKey,
        state: inout EndpointState
    ) -> Bool {
        guard let featureID = state.batteryFeatureID,
              let feature = HIDPPFeature(rawValue: featureID) else { return false }
        let parameters = Array(packet.parameters)
        var battery: LogitechBattery?

        switch feature {
        case .unifiedBattery:
            if packet.softwareID == HIDPPPacket.softwareID, packet.function == 0 {
                guard parameters.count >= 2 else { return true }
                state.unifiedBatteryHasPercentage = parameters[1] & 0x02 != 0
                endpoints[key] = state
                guard let featureIndex = state.batteryFeatureIndex else { return true }
                send(connection, HIDPPPacket.request(deviceIndex: key.deviceIndex, featureIndex: featureIndex, function: 1))
                return true
            }
            guard (packet.softwareID == HIDPPPacket.softwareID && packet.function == 1) ||
                    (packet.softwareID != HIDPPPacket.softwareID && packet.function == 0) else { return false }
            battery = HIDPPBatteryParser.unified(parameters, hasPercentage: state.unifiedBatteryHasPercentage)
        case .batteryLevel:
            guard packet.function == 0 else { return false }
            battery = HIDPPBatteryParser.levelStatus(parameters)
        case .batteryVoltage:
            guard packet.function == 0 else { return false }
            battery = HIDPPBatteryParser.voltage(parameters)
        case .buttons:
            return false
        }

        guard let battery else { return true }
        let changed = state.battery != battery
        state.battery = battery
        endpoints[key] = state
        publishDevices()
        if changed { log("バッテリー: \(battery.displayText)") }
        return true
    }

    private func setDiversion(connection: HIDConnection, deviceIndex: UInt8, featureIndex: UInt8, controlID: UInt16, enabled: Bool) {
        // Byte 2: dvalid (bit 1) + divert (bit 0).
        let flags: UInt8 = enabled ? 0x03 : 0x02
        let parameters: [UInt8] = [UInt8(controlID >> 8), UInt8(controlID & 0xFF), flags, 0, 0]
        send(connection, HIDPPPacket.request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: 3, parameters: parameters))
        let name = sourceForControl(controlID)?.displayName ?? "ボタン"
        log(enabled ? "\(name)をアプリへ転送" : "\(name)の転送を解除")
    }

    private func send(_ connection: HIDConnection, _ report: [UInt8]) {
        let result = report.withUnsafeBytes { rawBuffer in
            IOHIDDeviceSetReport(
                connection.device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPPPacket.longReportID),
                rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
        if result != kIOReturnSuccess && result != kIOReturnNotOpen {
            log("HID++送信エラー: 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
    }

    private func publishDevices() {
        var devices: [LogitechDevice] = []
        for (key, state) in endpoints.sorted(by: { $0.key.deviceIndex < $1.key.deviceIndex }) {
            guard let connection = connections[key.connectionID] else { continue }
            let precision = state.controls.first(where: { sourceForControl($0.id) == .precision })?.id
            devices.append(LogitechDevice(
                id: "\(key.connectionID)-\(key.deviceIndex)",
                name: precision == nil ? "Logitech HID++ (slot \(key.deviceIndex))" : "MX ERGO",
                deviceIndex: key.deviceIndex,
                transport: connection.transport,
                precisionControlID: precision,
                controls: state.controls,
                battery: state.battery
            ))
        }
        onDevicesChanged?(devices)
    }

    private func sourceForControl(_ id: UInt16) -> ButtonSource? {
        switch id {
        case 0x0050: .left
        case 0x0051: .right
        case 0x0053, 0x0054, 0x00BD, 0x00CE: .back
        case 0x0056, 0x0057, 0x00CF: .forward
        case 0x00ED, 0x00FD: .precision
        default: nil
        }
    }

    private func pressedSources<S: Sequence>(in controls: S) -> Set<ButtonSource> where S.Element == UInt16 {
        Set(controls.compactMap(sourceForControl))
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func stringProperty(_ device: IOHIDDevice, key: CFString) -> String? {
        IOHIDDeviceGetProperty(device, key) as? String
    }

    private func intProperty(_ device: IOHIDDevice, key: CFString) -> Int? {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue
    }
}

enum HIDPPBatteryParser {
    static func unified(_ parameters: [UInt8], hasPercentage: Bool) -> LogitechBattery? {
        guard parameters.count >= 4 else { return nil }
        let state = unifiedState(parameters[2])
        let level = unifiedLevel(parameters[1])
        let percentage = hasPercentage ? min(100, Int(parameters[0])) : nil
        return LogitechBattery(
            percentage: state == .full ? 100 : percentage,
            level: state == .full ? .full : level,
            state: state,
            voltageMillivolts: nil,
            featureID: HIDPPFeature.unifiedBattery.rawValue
        )
    }

    static func levelStatus(_ parameters: [UInt8]) -> LogitechBattery? {
        guard parameters.count >= 3 else { return nil }
        let state: LogitechBatteryState
        switch parameters[2] {
        case 0: state = .discharging
        case 1, 2, 4: state = .charging
        case 3: state = .full
        case 5...7: state = .error
        default: state = .unknown
        }
        let rawPercentage = min(100, Int(parameters[0]))
        let percentage: Int? = state == .full ? 100 : (state == .discharging ? rawPercentage : nil)
        return LogitechBattery(
            percentage: percentage,
            level: state == .full ? .full : level(for: rawPercentage),
            state: state,
            voltageMillivolts: nil,
            featureID: HIDPPFeature.batteryLevel.rawValue
        )
    }

    static func voltage(_ parameters: [UInt8]) -> LogitechBattery? {
        guard parameters.count >= 3 else { return nil }
        let millivolts = Int(parameters[0]) << 8 | Int(parameters[1])
        let flags = parameters[2]
        let state: LogitechBatteryState
        if flags & 0x80 == 0 {
            state = .discharging
        } else {
            switch flags & 0x07 {
            case 0: state = .charging
            case 1: state = .full
            case 2: state = .error
            default: state = .unknown
            }
        }
        return LogitechBattery(
            percentage: state == .full ? 100 : nil,
            level: flags & 0x20 != 0 ? .critical : (state == .full ? .full : .unknown),
            state: state,
            voltageMillivolts: millivolts,
            featureID: HIDPPFeature.batteryVoltage.rawValue
        )
    }

    private static func unifiedState(_ value: UInt8) -> LogitechBatteryState {
        switch value {
        case 0: .discharging
        case 1, 2: .charging
        case 3: .full
        case 4: .error
        default: .unknown
        }
    }

    private static func unifiedLevel(_ flags: UInt8) -> LogitechBatteryLevel {
        if flags & 0x08 != 0 { return .full }
        if flags & 0x04 != 0 { return .good }
        if flags & 0x02 != 0 { return .low }
        if flags & 0x01 != 0 { return .critical }
        return .unknown
    }

    private static func level(for percentage: Int) -> LogitechBatteryLevel {
        switch percentage {
        case ..<11: .critical
        case ..<30: .low
        case ..<81: .good
        default: .full
        }
    }
}

private let hidDeviceAdded: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
}

private let hidDeviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

private let hidInputReport: IOHIDReportCallback = { context, result, sender, _, _, report, reportLength in
    guard result == kIOReturnSuccess, let context, let sender else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue().received(bytes, from: device)
}
