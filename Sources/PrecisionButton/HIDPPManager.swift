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
    /// 0x8F is the HID++ 1.0 error the receiver sends for an empty slot;
    /// 0xFF is the HID++ 2.0 error a device sends for a bad request.
    var isError: Bool { featureIndex == 0x8F || featureIndex == 0xFF }
    /// Notifications carry software ID 0; every reply echoes the ID of the
    /// request it answers.
    var isNotification: Bool { softwareID == 0 }

    static func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8] = [],
        softwareID: UInt8 = HIDPPPacket.softwareID
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 20)
        result[0] = longReportID
        result[1] = deviceIndex
        result[2] = featureIndex
        result[3] = (function << 4) | (softwareID & 0x0F)
        for (offset, byte) in parameters.prefix(16).enumerated() {
            result[4 + offset] = byte
        }
        return result
    }

    static func rootFeatureRequest(deviceIndex: UInt8, featureID: UInt16, softwareID: UInt8 = HIDPPPacket.softwareID) -> [UInt8] {
        request(
            deviceIndex: deviceIndex,
            featureIndex: 0,
            function: 0,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)],
            softwareID: softwareID
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
    var isOpen = false

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

/// Only the trackballs this app was built and tested against are driven. Any
/// other Logitech device keeps its stock behavior.
enum SupportedDevice: String, CaseIterable {
    case mxErgo = "MX ERGO"
    case m575 = "M575"

    static func match(name: String) -> SupportedDevice? {
        let normalized = name.uppercased()
        return allCases.first { normalized.contains($0.rawValue) }
    }
}

private struct NameProbe {
    var featureIndex: UInt8
    var expectedLength: Int?
    var characters: [UInt8] = []
    /// Software ID of the request currently outstanding; nil between steps.
    var awaitingSoftwareID: UInt8?
}

/// A root getFeature reply names only the feature index, not the feature
/// that was asked for, so the reply is tied to the request by software ID.
private struct PendingRootRequest {
    var feature: HIDPPFeature
    var softwareID: UInt8
}

/// What a rescan knew about a device before it threw the state away. Filled
/// back in only when the new enumeration provably came up short.
private struct RetainedEndpoint {
    var name: String
    var count: Int?
    var controls: [HIDPPControl]
}

private struct EndpointState {
    var buttonFeatureIndex: UInt8
    var count: Int?
    var countRequestSoftwareID: UInt8?
    var controls: [HIDPPControl] = []
    var pressed: Set<UInt16> = []
    var batteryFeatureID: UInt16?
    var batteryFeatureIndex: UInt8?
    var unifiedBatteryHasPercentage = false
    var battery: LogitechBattery?
    var changeHostFeatureIndex: UInt8?
    var hostCount: Int?
    var currentHost: Int?

    var canChangeHost: Bool {
        changeHostFeatureIndex != nil && (hostCount ?? 0) > 1 && currentHost != nil
    }
}

private enum HIDPPFeature: UInt16 {
    case deviceName = 0x0005
    case buttons = 0x1B04
    case changeHost = 0x1814
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
    private var pendingRootFeatures: [EndpointKey: PendingRootRequest] = [:]
    private var nameProbes: [EndpointKey: NameProbe] = [:]
    private var identifiedDevices: [EndpointKey: String] = [:]
    private var diversionEnabled = true
    private var customizedSources: Set<ButtonSource> = []
    private var lastPressedEndpoint: EndpointKey?
    /// What we last told each control to do, so a periodic re-send does not
    /// fill the log with lines that say nothing changed.
    private var lastSentDiversion: [UInt16: Bool] = [:]
    private var started = false
    /// Wireless HID++ replies get lost. Every request that expects one is
    /// re-sent until it arrives or the attempts run out; these bound that.
    /// A Bluetooth device that has lengthened its connection interval while
    /// idle can take most of a second to answer, so the timeout errs long.
    private static let replyTimeout: TimeInterval = 1.0
    private static let maxAttempts = 3
    private static let controlRequestSpacing: TimeInterval = 0.025
    /// Bumped by every rescan so a retry scheduled for the previous scan
    /// cannot re-send into the new one.
    private var scanGeneration = 0
    private var retainedEndpoints: [EndpointKey: RetainedEndpoint] = [:]
    /// Rotates through 1...12. Skips 0 (notifications) and the fixed 0x0D
    /// that requests without a retry still use, so a reply to an earlier
    /// send can never be mistaken for the one currently awaited.
    private var nextSoftwareID: UInt8 = 1

    private func allocateSoftwareID() -> UInt8 {
        let id = nextSoftwareID
        nextSoftwareID = id >= 12 ? 1 : id + 1
        return id
    }

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
        log(result == kIOReturnSuccess
            ? L("Logitech HIDの監視を開始")
            : L("HID監視を開始できません (0x%@)", String(UInt32(bitPattern: result), radix: 16)))
    }

    func rescan() {
        for source in pressedSources(in: endpoints.values.flatMap(\.pressed)) { onButton?(source, false) }
        // Keep what the last scan found: this one may lose a reply, and a
        // shorter button list must never replace a complete one. A scan that
        // is itself still short (interrupted by this rescan) is not kept
        // either, so the older complete snapshot survives it.
        for (key, state) in endpoints {
            guard let name = identifiedDevices[key], let count = state.count, state.controls.count >= count else { continue }
            retainedEndpoints[key] = RetainedEndpoint(name: name, count: count, controls: state.controls)
        }
        scanGeneration += 1
        endpoints.removeAll()
        pendingRootFeatures.removeAll()
        nameProbes.removeAll()
        identifiedDevices.removeAll()
        lastSentDiversion.removeAll()
        publishDevices()
        log(L("HID++デバイスを再スキャン"))
        for connection in connections.values where open(connection) {
            probe(connection)
        }
    }

    /// Both halves of the decision in one call. Applying them separately meant
    /// the first pass ran against a stale set of customized sources, which left
    /// the wheel tilts and Easy-Switch un-diverted whenever the app toggled
    /// between enabled and disabled.
    func setState(enabled: Bool, customizedSources sources: Set<ButtonSource>) {
        let changed = enabled != diversionEnabled || sources != customizedSources
        diversionEnabled = enabled
        customizedSources = sources
        applyDiversion()
        if changed {
            log(enabled ? L("ボタンのカスタマイズを有効化") : L("ボタンを標準動作に復帰"))
        }
    }

    /// Re-sends the current diversion to every device. The flag lives on the
    /// device and is lost when it sleeps or re-connects, so it has to be
    /// refreshed even when nothing on our side changed.
    func refreshDiversion() {
        applyDiversion()
    }

    private func applyDiversion() {
        for (key, state) in endpoints {
            guard let connection = connections[key.connectionID] else { continue }
            for control in state.controls where control.isDivertable {
                guard let source = sourceForControl(control.id) else { continue }
                setDiversion(
                    connection: connection,
                    deviceIndex: key.deviceIndex,
                    featureIndex: state.buttonFeatureIndex,
                    controlID: control.id,
                    enabled: shouldDivert(source, on: state)
                )
            }
        }
    }

    /// Cycles the mouse to its next paired host, the Easy-Switch behavior.
    @discardableResult
    func switchToNextHost() -> String {
        // The device whose button was pressed must be the one that switches,
        // never a different trackball that happens to support the feature.
        var candidates = endpoints.sorted(by: { $0.key.deviceIndex < $1.key.deviceIndex })
        if let origin = lastPressedEndpoint, let index = candidates.firstIndex(where: { $0.key == origin }) {
            let preferred = candidates.remove(at: index)
            guard preferred.value.canChangeHost else {
                return L("このデバイスはソフトからの切り替えに対応していません")
            }
            candidates.insert(preferred, at: 0)
        }
        for (key, state) in candidates {
            guard let featureIndex = state.changeHostFeatureIndex,
                  let count = state.hostCount, count > 1,
                  let current = state.currentHost,
                  let connection = connections[key.connectionID] else { continue }
            let next = (current + 1) % count
            send(connection, HIDPPPacket.request(
                deviceIndex: key.deviceIndex,
                featureIndex: featureIndex,
                function: 1,
                parameters: [UInt8(next)]
            ))
            // The mouse leaves this host right away, so no reply is expected.
            var updated = state
            updated.currentHost = next
            endpoints[key] = updated
            return L("デバイス切り替え: チャンネル%@へ", next + 1)
        }
        return L("デバイス切り替えに対応したデバイスが見つかりません")
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
        guard open(connection) else { return }
        log(L("%@（%@）を検出", product, transport))
        probe(connection)
    }

    /// The device-matching callback fires only once per device, so a failed
    /// open must stay retryable from L("再スキャン") after permissions change.
    @discardableResult
    private func open(_ connection: HIDConnection) -> Bool {
        if connection.isOpen { return true }
        let result = IOHIDDeviceOpen(connection.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let reason = result == kIOReturnNotPermitted
                ? L("入力監視の許可を確認してください（アプリ更新後は登録し直しが必要です）")
                : L("他のアプリが占有している可能性があります")
            log(L(
                "%@を開けません（0x%@）。%@",
                connection.product,
                String(UInt32(bitPattern: result), radix: 16),
                reason
            ))
            return false
        }
        connection.isOpen = true
        return true
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
        nameProbes = nameProbes.filter { $0.key.connectionID != entry.key }
        identifiedDevices = identifiedDevices.filter { $0.key.connectionID != entry.key }
        retainedEndpoints = retainedEndpoints.filter { $0.key.connectionID != entry.key }
        publishDevices()
        log(L("%@が切断されました", entry.value.product))
    }

    fileprivate func received(_ bytes: [UInt8], from device: IOHIDDevice) {
        guard let connection = connections.values.first(where: { $0.device === device }), bytes.count >= 7 else { return }
        let packet = HIDPPPacket(bytes: bytes)
        guard packet.bytes[0] == 0x10 || packet.bytes[0] == 0x11 else { return }

        let key = EndpointKey(connectionID: connection.id, deviceIndex: packet.deviceIndex)
        if packet.isError {
            // An error is still a reply. The receiver answers this way for an
            // empty slot, and re-sending would only get the same answer.
            // Bytes 3 and 4 repeat the failed request's feature index and
            // function/software ID.
            if bytes.count > 4, bytes[3] == 0,
               let pending = pendingRootFeatures[key], bytes[4] & 0x0F == pending.softwareID {
                pendingRootFeatures.removeValue(forKey: key)
            }
            return
        }

        if packet.featureIndex == 0, packet.function == 0, !packet.isNotification {
            // A reply to an earlier send of the same request, arriving after
            // its retry was already answered, must not be taken for the
            // answer to whatever root request came next.
            guard bytes.count > 4, let pending = pendingRootFeatures[key],
                  packet.softwareID == pending.softwareID else { return }
            pendingRootFeatures.removeValue(forKey: key)
            let requestedFeature = pending.feature
            let featureIndex = bytes[4]
            if requestedFeature == .deviceName {
                guard featureIndex != 0 else { return }
                nameProbes[key] = NameProbe(featureIndex: featureIndex)
                sendNameRequest(connection, key: key, function: 0, offset: 0)
                return
            }
            if requestedFeature == .buttons {
                guard featureIndex != 0 else { return }
                endpoints[key] = EndpointState(buttonFeatureIndex: featureIndex)
                log(L("HID++スロット%@: ボタン機能を検出", packet.deviceIndex))
                requestControlCount(connection, key: key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.requestRootFeature(.unifiedBattery, connection: connection, deviceIndex: packet.deviceIndex)
                }
                return
            }

            guard var state = endpoints[key] else { return }

            if requestedFeature == .changeHost {
                guard featureIndex != 0 else {
                    log(L("HID++スロット%@: デバイス切り替えは非対応", packet.deviceIndex))
                    return
                }
                state.changeHostFeatureIndex = featureIndex
                endpoints[key] = state
                send(connection, HIDPPPacket.request(deviceIndex: packet.deviceIndex, featureIndex: featureIndex, function: 0))
                return
            }

            guard featureIndex != 0 else {
                requestNextBatteryFeature(after: requestedFeature, connection: connection, deviceIndex: packet.deviceIndex)
                return
            }
            state.batteryFeatureID = requestedFeature.rawValue
            state.batteryFeatureIndex = featureIndex
            endpoints[key] = state
            log(L(
                "HID++スロット%@: バッテリー機能 0x%@ を検出",
                String(packet.deviceIndex),
                String(requestedFeature.rawValue, radix: 16).uppercased()
            ))
            requestBatteryStatus(connection: connection, key: key, state: state)
            requestRootFeature(.changeHost, connection: connection, deviceIndex: packet.deviceIndex)
            return
        }

        if let probe = nameProbes[key], packet.featureIndex == probe.featureIndex, !packet.isNotification {
            handleNameResponse(packet, connection: connection, key: key)
            return
        }

        guard var state = endpoints[key] else { return }

        // CHANGE_HOST getHostInfo: [nbHost, currHost] (currHost is 0-based).
        if packet.featureIndex == state.changeHostFeatureIndex, packet.function == 0, bytes.count >= 6 {
            state.hostCount = Int(bytes[4])
            state.currentHost = Int(bytes[5])
            endpoints[key] = state
            log(L("HID++スロット%@: デバイス切り替え対応（%@/%@）", packet.deviceIndex, bytes[5] + 1, bytes[4]))
            // Easy-Switch diversion depends on this capability, so re-apply it.
            applyDiversion()
            return
        }

        if packet.featureIndex == state.batteryFeatureIndex,
           handleBatteryPacket(packet, connection: connection, key: key, state: &state) {
            return
        }

        guard packet.featureIndex == state.buttonFeatureIndex else { return }

        if !packet.isNotification, packet.function == 0 {
            // Only the send currently awaited counts. A late reply to an
            // earlier send, or a second reply after the first was accepted,
            // must not start another enumeration on top of the running one.
            guard state.count == nil, packet.softwareID == state.countRequestSoftwareID else { return }
            state.count = Int(bytes[4])
            state.countRequestSoftwareID = nil
            endpoints[key] = state
            requestAllControls(connection, key: key)
            return
        }

        if !packet.isNotification, packet.function == 1, bytes.count >= 9 {
            let cid = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let control = HIDPPControl(id: cid, flags: bytes[8])
            // A retry asks for every control again; the ones that already
            // answered were logged, diverted and published the first time.
            guard !state.controls.contains(where: { $0.id == cid }) else { return }
            state.controls.append(control)
            endpoints[key] = state
            if let source = sourceForControl(cid) {
                log(L("%@を検出（CID 0x%@）", source.displayName, String(cid, radix: 16).uppercased()))
                if control.isDivertable, shouldDivert(source, on: state) {
                    setDiversion(connection: connection, deviceIndex: packet.deviceIndex, featureIndex: state.buttonFeatureIndex, controlID: cid, enabled: true)
                }
                // Publish on every control: the UI builds its button list from
                // this snapshot, and the tilts arrive after the precision
                // button, so publishing only for that one hid them.
                publishDevices()
            } else {
                // Unmapped controls are logged so a button we do not know yet
                // can be identified from its CID.
                let note = control.isDivertable ? "" : L(" / 転送不可")
                log(L("未対応のボタン（CID 0x%@%@）", String(cid, radix: 16).uppercased(), note))
            }
            return
        }

        // Event 0 reports the complete set of currently pressed diverted controls.
        if packet.isNotification, packet.function == 0 {
            var nowPressed = Set<UInt16>()
            for offset in stride(from: 4, through: min(bytes.count - 2, 10), by: 2) {
                let cid = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                if cid != 0 { nowPressed.insert(cid) }
            }
            let before = pressedSources(in: state.pressed)
            let after = pressedSources(in: nowPressed)
            state.pressed = nowPressed
            endpoints[key] = state
            if !after.isEmpty { lastPressedEndpoint = key }
            for source in after.subtracting(before) { onButton?(source, true) }
            for source in before.subtracting(after) { onButton?(source, false) }
        }
    }

    private func probe(_ connection: HIDConnection) {
        // Identify the model before touching any button: an unsupported device
        // must never have its controls diverted.
        for (offset, deviceIndex) in connection.candidateIndices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(offset) * 0.08) { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.requestRootFeature(.deviceName, connection: connection, deviceIndex: deviceIndex)
            }
        }
    }

    private func handleNameResponse(_ packet: HIDPPPacket, connection: HIDConnection, key: EndpointKey) {
        // A name chunk does not say which offset it is for, so a late reply
        // to an earlier send would be appended as the next chunk. Only the
        // send being waited on is accepted.
        guard var probe = nameProbes[key], packet.softwareID == probe.awaitingSoftwareID else { return }
        probe.awaitingSoftwareID = nil
        nameProbes[key] = probe
        let parameters = Array(packet.parameters)

        if packet.function == 0 {
            guard let length = parameters.first, length > 0 else { return }
            probe.expectedLength = Int(length)
            nameProbes[key] = probe
            sendNameRequest(connection, key: key, function: 1, offset: 0)
            return
        }

        guard packet.function == 1, let expected = probe.expectedLength else { return }
        probe.characters.append(contentsOf: parameters.prefix(16).prefix(expected - probe.characters.count))
        nameProbes[key] = probe

        if probe.characters.count < expected, !parameters.allSatisfy({ $0 == 0 }) {
            sendNameRequest(connection, key: key, function: 1, offset: probe.characters.count)
            return
        }

        nameProbes.removeValue(forKey: key)
        let name = String(decoding: probe.characters.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard SupportedDevice.match(name: name) != nil else {
            log(L("「%@」は非対応のため操作しません", name))
            return
        }
        identifiedDevices[key] = name
        log(L("%@を認識（スロット%@）", name, key.deviceIndex))
        requestRootFeature(.buttons, connection: connection, deviceIndex: key.deviceIndex)
    }

    private func requestRootFeature(_ feature: HIDPPFeature, connection: HIDConnection, deviceIndex: UInt8) {
        let key = EndpointKey(connectionID: connection.id, deviceIndex: deviceIndex)
        guard pendingRootFeatures[key] == nil else { return }
        let sendOnce: @Sendable () -> Void = { [weak self, weak connection] in
            guard let self, let connection else { return }
            let softwareID = self.allocateSoftwareID()
            self.pendingRootFeatures[key] = PendingRootRequest(feature: feature, softwareID: softwareID)
            self.send(connection, HIDPPPacket.rootFeatureRequest(
                deviceIndex: deviceIndex, featureID: feature.rawValue, softwareID: softwareID
            ))
        }
        sendOnce()
        awaitReply(
            key: key,
            what: L("機能検索"),
            // The name probe goes to every receiver slot, most of them empty.
            // A slot that never answers is the normal case, not a fault.
            quiet: feature == .deviceName,
            stillWaiting: { [weak self] in self?.pendingRootFeatures[key]?.feature == feature },
            resend: sendOnce,
            giveUp: { [weak self] in self?.pendingRootFeatures.removeValue(forKey: key) }
        )
    }

    /// Re-sends a request every `replyTimeout` while `stillWaiting` says its
    /// reply has not arrived, `maxAttempts` sends in total. A retry belongs to
    /// the scan that scheduled it: a rescan or a disconnect in between
    /// silently cancels it.
    private func awaitReply(
        key: EndpointKey,
        what: String,
        timeout: TimeInterval = HIDPPManager.replyTimeout,
        attempt: Int = 1,
        quiet: Bool = false,
        stillWaiting: @escaping @Sendable () -> Bool,
        resend: @escaping @Sendable () -> Void,
        giveUp: @escaping @Sendable () -> Void
    ) {
        let generation = scanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, generation == self.scanGeneration,
                  self.connections[key.connectionID] != nil, stillWaiting() else { return }
            if attempt >= Self.maxAttempts {
                if !quiet { self.log(L("HID++スロット%@: %@の応答が得られませんでした", key.deviceIndex, what)) }
                giveUp()
                return
            }
            if !quiet {
                self.log(L("HID++スロット%@: %@の応答がないため再送します（%@回目）", key.deviceIndex, what, attempt + 1))
            }
            resend()
            self.awaitReply(
                key: key, what: what, timeout: timeout, attempt: attempt + 1, quiet: quiet,
                stillWaiting: stillWaiting, resend: resend, giveUp: giveUp
            )
        }
    }

    private func sendNameRequest(_ connection: HIDConnection, key: EndpointKey, function: UInt8, offset: Int) {
        guard nameProbes[key] != nil else { return }
        let sendOnce: @Sendable () -> Void = { [weak self, weak connection] in
            guard let self, let connection, var probe = self.nameProbes[key] else { return }
            let softwareID = self.allocateSoftwareID()
            probe.awaitingSoftwareID = softwareID
            self.nameProbes[key] = probe
            self.send(connection, HIDPPPacket.request(
                deviceIndex: key.deviceIndex,
                featureIndex: probe.featureIndex,
                function: function,
                parameters: function == 0 ? [] : [UInt8(offset)],
                softwareID: softwareID
            ))
        }
        sendOnce()
        awaitReply(
            key: key,
            what: L("デバイス名"),
            // Unanswered means the probe still exists and has not moved past
            // the point this request was made from.
            stillWaiting: { [weak self] in
                guard let probe = self?.nameProbes[key], probe.awaitingSoftwareID != nil else { return false }
                return function == 0 ? probe.expectedLength == nil : probe.characters.count == offset
            },
            resend: sendOnce,
            giveUp: { [weak self] in self?.nameProbes.removeValue(forKey: key) }
        )
    }

    private func requestControlCount(_ connection: HIDConnection, key: EndpointKey) {
        guard endpoints[key] != nil else { return }
        let sendOnce: @Sendable () -> Void = { [weak self, weak connection] in
            guard let self, let connection, var state = self.endpoints[key] else { return }
            let softwareID = self.allocateSoftwareID()
            state.countRequestSoftwareID = softwareID
            self.endpoints[key] = state
            self.send(connection, HIDPPPacket.request(
                deviceIndex: key.deviceIndex, featureIndex: state.buttonFeatureIndex, function: 0, softwareID: softwareID
            ))
        }
        sendOnce()
        awaitReply(
            key: key,
            what: L("ボタン数"),
            stillWaiting: { [weak self] in
                guard let state = self?.endpoints[key] else { return false }
                return state.count == nil
            },
            resend: sendOnce,
            giveUp: { [weak self] in self?.carryOverRetainedControls(key: key) }
        )
    }

    /// getCidInfo does not echo the index it was asked for, so one missing
    /// reply cannot be re-requested on its own. Asking for every control
    /// again is cheap, and duplicates are dropped by CID.
    private func requestAllControls(_ connection: HIDConnection, key: EndpointKey) {
        guard let state = endpoints[key], let count = state.count else { return }
        let fire: @Sendable () -> Void = { [weak self, weak connection] in
            guard let self, let connection, let state = self.endpoints[key] else { return }
            let featureIndex = state.buttonFeatureIndex
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * Self.controlRequestSpacing) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.send(connection, HIDPPPacket.request(
                        deviceIndex: key.deviceIndex,
                        featureIndex: featureIndex,
                        function: 1,
                        parameters: [UInt8(index)]
                    ))
                }
            }
        }
        fire()
        awaitReply(
            key: key,
            what: L("ボタン情報"),
            timeout: Double(count) * Self.controlRequestSpacing + Self.replyTimeout,
            quiet: true,
            stillWaiting: { [weak self] in
                guard let state = self?.endpoints[key], let count = state.count else { return false }
                return state.controls.count < count
            },
            resend: { [weak self] in
                guard let self else { return }
                if let state = self.endpoints[key], let count = state.count {
                    self.log(L("HID++スロット%@: ボタン情報が%@/%@件しか揃わないため再送します", key.deviceIndex, state.controls.count, count))
                }
                fire()
            },
            giveUp: { [weak self] in self?.carryOverRetainedControls(key: key) }
        )
    }

    /// Runs when the enumeration gave up short. Anything the previous scan
    /// found on the same device, and this one did not, is put back and
    /// diverted again.
    private func carryOverRetainedControls(key: EndpointKey) {
        guard var state = endpoints[key],
              let retained = retainedEndpoints[key],
              retained.name == identifiedDevices[key] else { return }
        let missing = retained.controls.filter { control in !state.controls.contains { $0.id == control.id } }
        guard !missing.isEmpty else { return }
        let found = state.controls.count
        state.controls.append(contentsOf: missing)
        if state.count == nil { state.count = retained.count }
        endpoints[key] = state
        let total = state.count ?? state.controls.count
        log(L(
            "HID++スロット%@: 列挙が%@/%@件で終わったため、前回検出した%@個のボタンを引き継ぎました",
            key.deviceIndex, found, total, missing.count
        ))
        applyDiversion()
        publishDevices()
    }

    private func requestNextBatteryFeature(after feature: HIDPPFeature, connection: HIDConnection, deviceIndex: UInt8) {
        switch feature {
        case .unifiedBattery:
            requestRootFeature(.batteryLevel, connection: connection, deviceIndex: deviceIndex)
        case .batteryLevel:
            requestRootFeature(.batteryVoltage, connection: connection, deviceIndex: deviceIndex)
        case .batteryVoltage:
            log(L("HID++スロット%@: バッテリー情報は非対応", deviceIndex))
            requestRootFeature(.changeHost, connection: connection, deviceIndex: deviceIndex)
        case .buttons, .changeHost, .deviceName:
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
                    (packet.isNotification && packet.function == 0) else { return false }
            battery = HIDPPBatteryParser.unified(parameters, hasPercentage: state.unifiedBatteryHasPercentage)
        case .batteryLevel:
            guard packet.function == 0 else { return false }
            battery = HIDPPBatteryParser.levelStatus(parameters)
        case .batteryVoltage:
            guard packet.function == 0 else { return false }
            battery = HIDPPBatteryParser.voltage(parameters)
        case .buttons, .changeHost, .deviceName:
            return false
        }

        guard let battery else { return true }
        let changed = state.battery != battery
        state.battery = battery
        endpoints[key] = state
        publishDevices()
        if changed { log(L("バッテリー: %@", battery.displayText)) }
        return true
    }

    private func setDiversion(connection: HIDConnection, deviceIndex: UInt8, featureIndex: UInt8, controlID: UInt16, enabled: Bool) {
        let isRepeat = lastSentDiversion[controlID] == enabled
        lastSentDiversion[controlID] = enabled
        // Byte 2: dvalid (bit 1) + divert (bit 0).
        let flags: UInt8 = enabled ? 0x03 : 0x02
        let parameters: [UInt8] = [UInt8(controlID >> 8), UInt8(controlID & 0xFF), flags, 0, 0]
        send(connection, HIDPPPacket.request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: 3, parameters: parameters))
        guard !isRepeat else { return }
        let name = sourceForControl(controlID)?.displayName ?? L("ボタン")
        log(enabled ? L("%@をアプリへ転送", name) : L("%@の転送を解除", name))
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
            log(L("HID++送信エラー: 0x%@", String(UInt32(bitPattern: result), radix: 16)))
        }
    }

    private func publishDevices() {
        var devices: [LogitechDevice] = []
        for (key, state) in endpoints.sorted(by: { $0.key.deviceIndex < $1.key.deviceIndex }) {
            guard let connection = connections[key.connectionID] else { continue }
            let precision = state.controls.first(where: { sourceForControl($0.id) == .precision })?.id
            // Endpoints only exist for identified, supported devices.
            let name = identifiedDevices[key] ?? connection.product
            devices.append(LogitechDevice(
                id: "\(key.connectionID)-\(key.deviceIndex)",
                name: name,
                deviceIndex: key.deviceIndex,
                transport: connection.transport,
                precisionControlID: precision,
                controls: state.controls,
                battery: state.battery,
                supportsHostSwitch: state.canChangeHost
            ))
        }
        onDevicesChanged?(devices)
    }

    private func sourceForControl(_ id: UInt16) -> ButtonSource? {
        switch id {
        case 0x0050: .left
        case 0x0051: .right
        case 0x0052: .middle
        case 0x005B: .tiltLeft
        case 0x005D: .tiltRight
        case 0x0053, 0x0054, 0x00BD, 0x00CE: .back
        case 0x0056, 0x0057, 0x00CF: .forward
        case 0x00ED, 0x00FD: .precision
        // Easy-Switch / host switching controls.
        case 0x00D7, 0x0103, 0x0104, 0x0105: .deviceSwitch
        default: nil
        }
    }

    private func shouldDivert(_ source: ButtonSource, on state: EndpointState) -> Bool {
        guard diversionEnabled else { return false }
        guard source.divertsOnlyWhenCustomized else { return true }
        guard customizedSources.contains(source) else { return false }
        // Taking Easy-Switch away from a device we cannot switch in software
        // would leave it unable to change hosts at all.
        return source != .deviceSwitch || state.canChangeHost
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
