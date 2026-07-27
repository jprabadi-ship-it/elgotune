import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

@MainActor
final class AppModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            hid.setDiversionEnabled(effectiveEnabled)
            updateMouseCapture()
            if !isEnabled { resetButtonGesture() }
        }
    }
    @Published var mappings: [ButtonSource: ButtonMapping] {
        didSet {
            saveMappings()
            updateMouseCapture()
        }
    }
    @Published var longPressMilliseconds: Double {
        didSet { UserDefaults.standard.set(longPressMilliseconds, forKey: "longPressMilliseconds") }
    }
    @Published var excludedApps: [ExcludedApp] {
        didSet {
            saveExcludedApps()
            updateFrontmostExclusion()
        }
    }
    @Published private(set) var devices: [LogitechDevice] = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastPress: Date?
    @Published private(set) var heldSources: Set<ButtonSource> = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var eventPostingGranted = CGPreflightPostEventAccess()
    @Published private(set) var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published private(set) var isFrontmostAppExcluded = false

    private let hid = HIDPPManager()
    private let mouse = MouseButtonMonitor()
    private var gestureStates: [ButtonSource: ButtonGestureState] = [:]
    private var longPressWorkItems: [ButtonSource: DispatchWorkItem] = [:]
    private var directionalCooldownWorkItems: [ButtonSource: DispatchWorkItem] = [:]
    private var gestureMovement: [ButtonSource: CGPoint] = [:]
    private var triggeredDirectionalSources: Set<ButtonSource> = []
    private nonisolated(unsafe) var frontmostAppObserver: NSObjectProtocol?

    private static let directionalCooldownMilliseconds: Double = 350

    var statusText: String {
        if let device = devices.first(where: { $0.precisionControlID != nil }) {
            return "\(device.name): 精密モードボタンを検出"
        }
        if !devices.isEmpty { return "Logitechデバイスを調査中…" }
        return "MX ERGOを待機中…"
    }

    var ready: Bool {
        isEnabled && accessibilityGranted && eventPostingGranted && inputMonitoringGranted && devices.contains { $0.precisionControlID != nil }
    }

    var primaryBattery: LogitechBattery? {
        devices.first(where: { $0.precisionControlID != nil })?.battery
    }

    private var effectiveEnabled: Bool {
        isEnabled && accessibilityGranted && eventPostingGranted && inputMonitoringGranted && !isFrontmostAppExcluded
    }

    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true
        let legacyShort: ButtonAction
        if let data = UserDefaults.standard.data(forKey: "buttonAction"),
           let action = try? JSONDecoder().decode(ButtonAction.self, from: data) {
            legacyShort = action
        } else {
            legacyShort = .missionControl
        }
        let legacyLong: ButtonAction
        if let data = UserDefaults.standard.data(forKey: "longPressAction"),
           let action = try? JSONDecoder().decode(ButtonAction.self, from: data) {
            legacyLong = action
        } else {
            legacyLong = .commandBackspace
        }
        if let data = UserDefaults.standard.data(forKey: "buttonMappings"),
           let saved = try? JSONDecoder().decode([ButtonSource: ButtonMapping].self, from: data) {
            self.mappings = saved
        } else {
            self.mappings = [
                .precision: ButtonMapping(shortPress: legacyShort, longPress: legacyLong),
                .left: ButtonMapping(shortPress: .leftClick, longPress: .none),
                .right: ButtonMapping(shortPress: .rightClick, longPress: .none),
                .back: ButtonMapping(shortPress: .backClick, longPress: .none),
                .forward: ButtonMapping(shortPress: .forwardClick, longPress: .none)
            ]
        }
        if let savedMilliseconds = UserDefaults.standard.object(forKey: "longPressMilliseconds") as? NSNumber,
           savedMilliseconds.doubleValue > 0 {
            self.longPressMilliseconds = savedMilliseconds.doubleValue
        } else {
            let legacySeconds = UserDefaults.standard.double(forKey: "longPressDuration")
            self.longPressMilliseconds = legacySeconds > 0 ? legacySeconds * 1_000 : 600
        }
        if let data = UserDefaults.standard.data(forKey: "excludedApps"),
           let saved = try? JSONDecoder().decode([ExcludedApp].self, from: data) {
            self.excludedApps = saved
        } else {
            self.excludedApps = []
        }
        self.isFrontmostAppExcluded = Self.isExcluded(
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            in: self.excludedApps
        )
        UserDefaults.standard.set(self.longPressMilliseconds, forKey: "longPressMilliseconds")

        hid.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.devices = devices }
        }
        hid.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        hid.onButton = { [weak self] source, pressed in
            Task { @MainActor in self?.handleButtonState(source: source, pressed: pressed) }
        }
        mouse.onButton = { [weak self] source, pressed in
            Task { @MainActor in self?.handleButtonState(source: source, pressed: pressed) }
        }
        mouse.onMotion = { [weak self] source, dx, dy in
            Task { @MainActor in self?.handleMotion(source: source, deltaX: dx, deltaY: dy) }
        }
        mouse.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        hid.start(diversionEnabled: effectiveEnabled)
        mouse.start()
        updateMouseCapture()
        appendLog(eventPostingGranted ? "キーボード・マウス操作の送信権限を確認" : "操作送信権限がありません")

        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.updateFrontmostExclusion(bundleIdentifier: app?.bundleIdentifier) }
        }
    }

    deinit {
        if let frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
        }
    }

    func requestPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshPermissions()
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        eventPostingGranted = CGPreflightPostEventAccess()
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        hid.setDiversionEnabled(effectiveEnabled)
        mouse.start()
    }

    func rescan() {
        hid.rescan()
    }

    func refreshBattery() {
        hid.refreshBattery()
    }

    func addExcludedApp(bundleIdentifier: String, name: String) {
        guard !excludedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        excludedApps.append(ExcludedApp(bundleIdentifier: bundleIdentifier, name: name))
    }

    func addExcludedApp(at url: URL) {
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        addExcludedApp(bundleIdentifier: bundleIdentifier, name: name)
    }

    func removeExcludedApps(at offsets: IndexSet) {
        excludedApps.remove(atOffsets: offsets)
    }

    func excludableRunningApps() -> [(bundleIdentifier: String, name: String, icon: NSImage?)] {
        let excludedIDs = Set(excludedApps.map(\.bundleIdentifier))
        let ownBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bundleIdentifier = app.bundleIdentifier,
                      bundleIdentifier != ownBundleID,
                      !excludedIDs.contains(bundleIdentifier) else { return nil }
                return (bundleIdentifier, app.localizedName ?? bundleIdentifier, app.icon)
            }
            .sorted { $0.1 < $1.1 }
    }

    private func saveExcludedApps() {
        if let data = try? JSONEncoder().encode(excludedApps) {
            UserDefaults.standard.set(data, forKey: "excludedApps")
        }
    }

    private static func isExcluded(bundleIdentifier: String?, in excludedApps: [ExcludedApp]) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func updateFrontmostExclusion(
        bundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) {
        let excluded = Self.isExcluded(bundleIdentifier: bundleIdentifier, in: excludedApps)
        guard excluded != isFrontmostAppExcluded else { return }
        isFrontmostAppExcluded = excluded
        hid.setDiversionEnabled(effectiveEnabled)
        updateMouseCapture()
        if excluded {
            resetButtonGesture()
            appendLog("除外アプリがアクティブなためボタンを標準動作に戻します")
        } else {
            appendLog("除外アプリから復帰、カスタマイズを再開します")
        }
    }

    func mapping(for source: ButtonSource) -> ButtonMapping {
        mappings[source] ?? ButtonMapping(shortPress: source.nativeAction, longPress: .none)
    }

    func setMapping(_ mapping: ButtonMapping, for source: ButtonSource) {
        mappings[source] = mapping
    }

    private func handleButtonState(source: ButtonSource, pressed: Bool) {
        guard isEnabled else {
            resetButtonGesture()
            return
        }

        if pressed {
            var state = gestureStates[source] ?? ButtonGestureState()
            guard state.beginPress() else { return }
            gestureStates[source] = state
            gestureMovement[source] = .zero
            triggeredDirectionalSources.remove(source)
            appendLog("\(source.displayName): 押下を検出")
            let workItem = DispatchWorkItem { [weak self] in
                self?.triggerLongPressIfNeeded(for: source)
            }
            longPressWorkItems[source]?.cancel()
            longPressWorkItems[source] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressMilliseconds / 1_000, execute: workItem)
            return
        }

        longPressWorkItems[source]?.cancel()
        longPressWorkItems[source] = nil
        directionalCooldownWorkItems[source]?.cancel()
        directionalCooldownWorkItems[source] = nil
        var state = gestureStates[source] ?? ButtonGestureState()
        let wasLongPress = state.didTriggerLongPress
        if wasLongPress, mapping(for: source).longPressMode == .directions {
            triggerDirectionalGestureIfNeeded(for: source)
            if !triggeredDirectionalSources.contains(source) {
                appendLog("\(source.displayName): 方向移動が小さいためキャンセル")
            }
        }
        let outcome = state.endPress()
        gestureStates[source] = state
        if outcome == .shortPress {
            perform(mapping(for: source).shortPress, source: source, gestureName: "短押し")
        }
        if wasLongPress {
            heldSources.remove(source)
            appendLog("\(source.displayName): 押しっぱなし終了")
        } else {
            appendLog("\(source.displayName): 解放を検出")
        }
        gestureMovement[source] = nil
        triggeredDirectionalSources.remove(source)
    }

    private func triggerLongPressIfNeeded(for source: ButtonSource) {
        var state = gestureStates[source] ?? ButtonGestureState()
        let outcome = state.reachLongPressThreshold()
        gestureStates[source] = state
        guard outcome == .longPress else { return }
        heldSources.insert(source)
        let value = mapping(for: source)
        switch value.longPressMode {
        case .action:
            perform(value.longPress, source: source, gestureName: "押しっぱなし開始")
        case .scroll:
            let movement = gestureMovement[source] ?? .zero
            gestureMovement[source] = .zero
            ActionPerformer.scroll(deltaX: movement.x, deltaY: movement.y)
            appendLog("\(source.displayName): スクロールモード開始")
        case .directions:
            appendLog("\(source.displayName): 方向ジェスチャー開始")
            triggerDirectionalGestureIfNeeded(for: source)
        }
    }

    private func handleMotion(source: ButtonSource, deltaX: Double, deltaY: Double) {
        guard let state = gestureStates[source], state.isPressed else { return }
        let mode = mapping(for: source).longPressMode
        if state.didTriggerLongPress, mode == .scroll {
            ActionPerformer.scroll(deltaX: deltaX, deltaY: deltaY)
            return
        }
        var movement = gestureMovement[source] ?? .zero
        movement.x += deltaX
        movement.y += deltaY
        gestureMovement[source] = movement
        if state.didTriggerLongPress, mode == .directions {
            triggerDirectionalGestureIfNeeded(for: source)
        }
    }

    private func triggerDirectionalGestureIfNeeded(for source: ButtonSource) {
        guard !triggeredDirectionalSources.contains(source),
              gestureStates[source]?.didTriggerLongPress == true else { return }
        let movement = gestureMovement[source] ?? .zero
        guard let direction = GestureDirection.dominant(deltaX: movement.x, deltaY: movement.y) else { return }
        triggeredDirectionalSources.insert(source)
        let action = mapping(for: source).action(for: direction)
        perform(action, source: source, gestureName: "押しっぱなし + \(direction.displayName)")
        scheduleDirectionalCooldown(for: source)
    }

    private func scheduleDirectionalCooldown(for source: ButtonSource) {
        directionalCooldownWorkItems[source]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.gestureStates[source]?.isPressed == true,
                  self.gestureStates[source]?.didTriggerLongPress == true,
                  self.mapping(for: source).longPressMode == .directions else { return }
            self.gestureMovement[source] = .zero
            self.triggeredDirectionalSources.remove(source)
            self.directionalCooldownWorkItems[source] = nil
            self.appendLog("\(source.displayName): 次の方向操作を待機")
        }
        directionalCooldownWorkItems[source] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.directionalCooldownMilliseconds / 1_000,
            execute: workItem
        )
    }

    private func perform(_ action: ButtonAction, source: ButtonSource, gestureName: String) {
        lastPress = Date()
        appendLog("\(source.displayName): \(gestureName) → \(action.displayName)")
        guard action == .none || CGPreflightPostEventAccess() else {
            appendLog("操作を送信できません: アクセシビリティの許可を確認してください")
            return
        }
        if let report = ActionPerformer.perform(action) {
            appendLog(report)
        }
    }

    private func resetButtonGesture() {
        for workItem in longPressWorkItems.values { workItem.cancel() }
        for workItem in directionalCooldownWorkItems.values { workItem.cancel() }
        longPressWorkItems.removeAll()
        directionalCooldownWorkItems.removeAll()
        gestureStates.removeAll()
        gestureMovement.removeAll()
        heldSources.removeAll()
        triggeredDirectionalSources.removeAll()
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date()))  \(line)")
        if logLines.count > 80 { logLines.removeFirst(logLines.count - 80) }
    }

    private func saveMappings() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "buttonMappings")
        }
    }

    private func updateMouseCapture() {
        let captured = Set([ButtonSource.left, .right].filter { source in
            guard effectiveEnabled else { return false }
            let value = mapping(for: source)
            return value.shortPress != source.nativeAction || value.longPress != .none || value.longPressMode != .action
        })
        mouse.setCapturedSources(captured)
    }
}

struct ExcludedApp: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String

    var id: String { bundleIdentifier }
}

struct LogitechDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var deviceIndex: UInt8
    var transport: String
    var precisionControlID: UInt16?
    var controls: [HIDPPControl]
    var battery: LogitechBattery?
}

enum LogitechBatteryState: Equatable {
    case discharging
    case charging
    case full
    case error
    case unknown

    var displayName: String {
        switch self {
        case .discharging: "使用中"
        case .charging: "充電中"
        case .full: "充電完了"
        case .error: "充電エラー"
        case .unknown: "状態不明"
        }
    }
}

enum LogitechBatteryLevel: Equatable {
    case critical
    case low
    case good
    case full
    case unknown

    var displayName: String {
        switch self {
        case .critical: "危険"
        case .low: "少ない"
        case .good: "良好"
        case .full: "満充電"
        case .unknown: "不明"
        }
    }
}

struct LogitechBattery: Equatable {
    var percentage: Int?
    var level: LogitechBatteryLevel
    var state: LogitechBatteryState
    var voltageMillivolts: Int?
    var featureID: UInt16

    var valueText: String {
        if let percentage { return "\(percentage)%" }
        if level != .unknown { return level.displayName }
        if let voltageMillivolts { return "\(voltageMillivolts) mV" }
        return "取得中…"
    }

    var displayText: String { "\(valueText)（\(state.displayName)）" }

    var systemImage: String {
        if state == .charging { return "battery.100percent.bolt" }
        if state == .full { return "battery.100percent" }
        guard let percentage else {
            return level == .critical || level == .low ? "battery.25percent" : "battery.75percent"
        }
        switch percentage {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct HIDPPControl: Equatable {
    let id: UInt16
    let flags: UInt8
    var isDivertable: Bool { flags & 0x20 != 0 }
}
