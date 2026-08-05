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
    @Published var pointerSettings: PointerSettings {
        didSet {
            if let data = try? JSONEncoder().encode(pointerSettings) {
                UserDefaults.standard.set(data, forKey: "pointerSettings")
            }
            applyPointerSettings()
        }
    }
    @Published var scrollSettings: ScrollSettings {
        didSet {
            if let data = try? JSONEncoder().encode(scrollSettings) {
                UserDefaults.standard.set(data, forKey: "scrollSettings")
            }
            mouse.setScrollSettings(scrollSettings)
            if !scrollSettings.momentumEnabled { stopMomentum() }
        }
    }
    @Published var excludedApps: [ExcludedApp] {
        didSet {
            saveExcludedApps()
            updateFrontmostExclusion()
        }
    }
    @Published private(set) var devices: [LogitechDevice] = []
    private var pointerAppliedDeviceIDs: Set<String> = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastPress: Date?
    @Published private(set) var heldSources: Set<ButtonSource> = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var eventPostingGranted = CGPreflightPostEventAccess()
    @Published private(set) var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published private(set) var isFrontmostAppExcluded = false
    @Published var launchAtLogin: Bool = LoginItem.isEnabled {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            if let message = LoginItem.setEnabled(launchAtLogin) {
                appendLog(message)
                launchAtLogin = LoginItem.isEnabled
            } else {
                appendLog(launchAtLogin ? L("ログイン時起動を有効化") : L("ログイン時起動を無効化"))
            }
        }
    }

    private let hid = HIDPPManager()
    private let mouse = MouseButtonMonitor()
    private var gestureStates: [ButtonSource: ButtonGestureState] = [:]
    private var longPressWorkItems: [ButtonSource: DispatchWorkItem] = [:]
    private var directionalCooldownWorkItems: [ButtonSource: DispatchWorkItem] = [:]
    private var gestureMovement: [ButtonSource: CGPoint] = [:]
    private var triggeredDirectionalSources: Set<ButtonSource> = []
    private let systemDefaultPointer: PointerSettings
    private var scrollVelocity: CGPoint = .zero
    private var momentumTimer: Timer?
    private var wheelIdleWorkItem: DispatchWorkItem?
    private nonisolated(unsafe) var frontmostAppObserver: NSObjectProtocol?
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private var healthTimer: Timer?
    /// The permission APIs cost 100 ms or more on macOS 27, so they are never
    /// called on the thread that has to stay responsive.
    private let permissionQueue = DispatchQueue(label: "com.elgotune.permissions", qos: .utility)
    private var permissionCheckInFlight = false
    private var lastPermissionCheck = Date.distantPast

    private static let directionalCooldownMilliseconds: Double = 350
    private static let healthCheckSeconds: Double = 5
    /// How often the slow permission APIs may be polled in the background.
    private static let permissionPollSeconds: Double = 30

    var statusText: String {
        guard !devices.isEmpty else { return L("Logitechデバイスを待機中…") }
        if devices.count == 1, let device = devices.first {
            let suffix = device.precisionControlID != nil ? L("精密モードボタンを検出") : L("%@個のボタンを検出", device.controls.count)
            return "\(device.name): \(suffix)"
        }
        return L("%@台を検出: ", devices.count) + devices.map(\.name).joined(separator: "、")
    }

    /// Any HID++ device with buttons is usable; the precision button is only
    /// present on MX ERGO.
    var deviceDetected: Bool { !devices.isEmpty }

    /// Buttons the connected devices actually offer. Left/right/middle come
    /// from the event tap and are always available; the rest need HID++.
    var availableSources: [ButtonSource] {
        ButtonSource.allCases.filter { source in
            switch source {
            case .left, .right, .middle:
                return true
            case .precision:
                return devices.contains { $0.precisionControlID != nil }
            case .deviceSwitch:
                // Present but useless unless the device can switch in software.
                return devices.contains { $0.supportsHostSwitch }
            case .tiltLeft, .tiltRight:
                return devices.contains { device in
                    device.controls.contains { $0.id == (source == .tiltLeft ? 0x005B : 0x005D) }
                }
            case .back, .forward:
                return devices.isEmpty || devices.contains { device in
                    device.controls.contains { control in
                        source == .back
                            ? [0x0053, 0x0054, 0x00BD, 0x00CE].contains(control.id)
                            : [0x0056, 0x0057, 0x00CF].contains(control.id)
                    }
                }
            }
        }
    }

    var ready: Bool {
        isEnabled && accessibilityGranted && eventPostingGranted && inputMonitoringGranted && deviceDetected
    }

    var primaryBattery: LogitechBattery? {
        devices.first(where: { $0.precisionControlID != nil })?.battery ?? devices.compactMap(\.battery).first
    }

    var deviceBatteries: [(name: String, battery: LogitechBattery)] {
        devices.compactMap { device in device.battery.map { (device.name, $0) } }
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
                .middle: ButtonMapping(shortPress: .middleClick, longPress: .none),
                .back: ButtonMapping(shortPress: .backClick, longPress: .none),
                .forward: ButtonMapping(shortPress: .forwardClick, longPress: .none),
                .tiltLeft: ButtonMapping(shortPress: .none, longPress: .none),
                .tiltRight: ButtonMapping(shortPress: .none, longPress: .none),
                .deviceSwitch: ButtonMapping(shortPress: .none, longPress: .none)
            ]
        }
        if let savedMilliseconds = UserDefaults.standard.object(forKey: "longPressMilliseconds") as? NSNumber,
           savedMilliseconds.doubleValue > 0 {
            self.longPressMilliseconds = savedMilliseconds.doubleValue
        } else {
            let legacySeconds = UserDefaults.standard.double(forKey: "longPressDuration")
            self.longPressMilliseconds = legacySeconds > 0 ? legacySeconds * 1_000 : 600
        }
        // Remember the value macOS had before this app first touched it.
        let systemAcceleration = PointerAcceleration.current()
        if UserDefaults.standard.object(forKey: "systemPointerAcceleration") == nil,
           let systemAcceleration {
            UserDefaults.standard.set(systemAcceleration, forKey: "systemPointerAcceleration")
        }
        self.systemDefaultPointer = PointerSettings(
            acceleration: UserDefaults.standard.object(forKey: "systemPointerAcceleration") as? Double
                ?? systemAcceleration ?? 3,
            speed: PointerSettings.neutralSpeed
        )
        if let data = UserDefaults.standard.data(forKey: "pointerSettings"),
           let saved = try? JSONDecoder().decode(PointerSettings.self, from: data) {
            self.pointerSettings = saved
        } else {
            self.pointerSettings = self.systemDefaultPointer
        }
        if let data = UserDefaults.standard.data(forKey: "scrollSettings"),
           let saved = try? JSONDecoder().decode(ScrollSettings.self, from: data) {
            self.scrollSettings = saved
        } else {
            self.scrollSettings = ScrollSettings()
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
            Task { @MainActor in
                guard let self else { return }
                let previous = self.availableSources
                self.devices = devices
                // Walking every HID service costs milliseconds, and this now
                // fires for each control discovered, so only apply when the
                // set of devices actually changed.
                let ids = Set(devices.map(\.id))
                if ids != self.pointerAppliedDeviceIDs {
                    self.pointerAppliedDeviceIDs = ids
                    self.applyPointerSettings()
                }
                // Recorded so a missing button in the picker is diagnosable.
                if self.availableSources != previous, !self.availableSources.isEmpty {
                    self.appendLog(L(
                        "設定できるボタン: %@",
                        self.availableSources.map(\.displayName).joined(separator: "、")
                    ))
                }
            }
        }
        hid.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        hid.onButton = { [weak self] source, pressed in
            Task { @MainActor in
                self?.routeMotion(for: source, pressed: pressed)
                self?.handleButtonState(source: source, pressed: pressed)
            }
        }
        mouse.onButton = { [weak self] source, pressed in
            Task { @MainActor in self?.handleButtonState(source: source, pressed: pressed) }
        }
        mouse.onWheel = { [weak self] deltaY, deltaX in
            Task { @MainActor in self?.handleWheel(deltaY: deltaY, deltaX: deltaX) }
        }
        mouse.onMotion = { [weak self] source, dx, dy in
            Task { @MainActor in self?.handleMotion(source: source, deltaX: dx, deltaY: dy) }
        }
        mouse.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        warmUpKeyEvents()
        hid.start(diversionEnabled: effectiveEnabled)
        mouse.start()
        mouse.setScrollSettings(scrollSettings)
        applyPointerSettings()
        updateMouseCapture()
        appendLog(eventPostingGranted ? L("キーボード・マウス操作の送信権限を確認") : L("操作送信権限がありません"))

        // Leaving the pointer rescaled, or buttons diverted to an app that is
        // gone, would strand the user with a device they cannot fix.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreDeviceState() }
        }

        // Permissions and the event tap have to recover without the settings
        // window: a launch during login can see permissions as missing, and a
        // tap can be torn down while the app sits in the menu bar.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouse.setOwnWindowFrames(self?.ownWindowFrames() ?? [])
                self?.refreshPermissions(force: true)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions(force: true)
                self?.rescan()
            }
        }
        let healthTimer = Timer(timeInterval: Self.healthCheckSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        self.healthTimer = healthTimer
        RunLoop.main.add(healthTimer, forMode: .common)

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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Hands the trackball back to macOS: stock pointer values and no diverted
    /// buttons. Called on quit.
    func restoreDeviceState() {
        stopMomentum()
        CursorFreeze.release()
        hid.setDiversionEnabled(false)
        PointerControl.apply(systemDefaultPointer)
        PointerAcceleration.apply(systemDefaultPointer.systemAcceleration)
        appendLog(L("終了時にデバイスを標準状態へ戻しました"))
    }

    var loginItemStatusText: String { LoginItem.statusText }

    var allPermissionsGranted: Bool {
        accessibilityGranted && eventPostingGranted && inputMonitoringGranted
    }

    /// Shown on first launch, and again whenever an update drops a permission.
    var shouldShowOnboarding: Bool {
        !allPermissionsGranted || !UserDefaults.standard.bool(forKey: "onboardingSeen")
    }

    func markOnboardingSeen() {
        UserDefaults.standard.set(true, forKey: "onboardingSeen")
    }

    var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return L("バージョン %@ (%@)", short, build)
    }

    /// What the device reports right now, so a failed write is visible.
    var systemAccelerationText: String {
        guard let values = PointerControl.currentValues() else { return L("デバイスの現在値を取得できません") }
        return String(format: L("デバイスの現在値: %.0f DPI / 加速 %.2f"), values.resolution, values.acceleration)
    }

    /// Restores the pointer curve macOS had before this app changed it.
    func resetPointerToSystemDefault() {
        pointerSettings = systemDefaultPointer
        appendLog(L("ポインタ設定をシステムデフォルトに戻しました"))
    }

    private func applyPointerSettings() {
        // Keep the legacy global value in sync for anything that reads it.
        PointerAcceleration.apply(pointerSettings.systemAcceleration)
        guard PointerControl.isAvailable else {
            appendLog(L("ポインタ設定を適用できません（この macOS では非対応）"))
            return
        }
        let applied = PointerControl.apply(pointerSettings)
        if applied == 0 { appendLog(L("ポインタ設定の対象デバイスが見つかりません")) }
    }

    func requestPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshPermissions(force: true)
    }

    /// Cheap upkeep: safe to run on the main thread every few seconds.
    private func checkHealth() {
        mouse.ensureRunning()
        mouse.setOwnWindowFrames(ownWindowFrames())
        refreshPermissions()
    }

    /// Frames of our own windows in CG coordinates, so the event tap can test
    /// them without asking the window server on every click.
    private func ownWindowFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSApplication.shared.windows.filter(\.isVisible).map { window in
            let frame = window.frame
            return CGRect(
                x: frame.minX,
                y: primary.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    func refreshPermissions(force: Bool = false) {
        guard !permissionCheckInFlight else { return }
        guard force || Date().timeIntervalSince(lastPermissionCheck) >= Self.permissionPollSeconds else { return }
        permissionCheckInFlight = true
        lastPermissionCheck = Date()

        permissionQueue.async { [weak self] in
            let accessibility = AXIsProcessTrusted()
            let eventPosting = CGPreflightPostEventAccess()
            let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            Task { @MainActor in
                self?.applyPermissionState(
                    accessibility: accessibility,
                    eventPosting: eventPosting,
                    inputMonitoring: inputMonitoring
                )
            }
        }
    }

    private func applyPermissionState(accessibility: Bool, eventPosting: Bool, inputMonitoring: Bool) {
        permissionCheckInFlight = false
        // The user may have approved the login item in System Settings.
        if launchAtLogin != LoginItem.isEnabled { launchAtLogin = LoginItem.isEnabled }

        let wasInputMonitoringGranted = inputMonitoringGranted
        let wasEffective = effectiveEnabled
        accessibilityGranted = accessibility
        eventPostingGranted = eventPosting
        inputMonitoringGranted = inputMonitoring

        // Re-applying unconditionally would fill the log with the same line
        // every few seconds, so only act when something actually changed.
        if effectiveEnabled != wasEffective {
            hid.setDiversionEnabled(effectiveEnabled)
            updateMouseCapture()
        }
        if inputMonitoring, !wasInputMonitoringGranted {
            // The devices could not be opened before the permission arrived.
            appendLog(L("入力監視が許可されました。デバイスを再スキャンします"))
            hid.rescan()
        }
        mouse.ensureRunning()
    }

    func rescan() {
        hid.rescan()
    }

    func refreshBattery() {
        hid.refreshBattery()
    }

    func exportSettings(to url: URL) {
        let bundle = SettingsBundle(
            mappings: mappings,
            longPressMilliseconds: longPressMilliseconds,
            excludedApps: excludedApps,
            scrollSettings: scrollSettings
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bundle).write(to: url, options: .atomic)
            appendLog(L("設定を書き出しました: %@", url.lastPathComponent))
        } catch {
            appendLog(L("設定の書き出しに失敗: %@", error.localizedDescription))
        }
    }

    func importSettings(from url: URL) {
        do {
            let bundle = try JSONDecoder().decode(SettingsBundle.self, from: Data(contentsOf: url))
            longPressMilliseconds = bundle.longPressMilliseconds
            excludedApps = bundle.excludedApps
            scrollSettings = bundle.scrollSettings
            resetButtonGesture()
            mappings = bundle.mappings
            appendLog(L("設定を読み込みました: %@", url.lastPathComponent))
        } catch {
            appendLog(L("設定の読み込みに失敗: %@", error.localizedDescription))
        }
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
            appendLog(L("除外アプリがアクティブなためボタンを標準動作に戻します"))
        } else {
            appendLog(L("除外アプリから復帰、カスタマイズを再開します"))
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
            // Any new press catches the glide, like a finger on a trackpad.
            stopMomentum()
            var state = gestureStates[source] ?? ButtonGestureState()
            guard state.beginPress() else { return }
            gestureStates[source] = state
            gestureMovement[source] = .zero
            triggeredDirectionalSources.remove(source)
            appendLog(L("%@: 押下を検出", source.displayName))
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
        if wasLongPress, mapping(for: source).longPressMode == .scroll {
            startMomentumIfNeeded(for: source)
        }
        if wasLongPress, mapping(for: source).longPressMode == .directions {
            CursorFreeze.release()
            triggerDirectionalGestureIfNeeded(for: source)
            if !triggeredDirectionalSources.contains(source) {
                appendLog(L("%@: 方向移動が小さいためキャンセル", source.displayName))
            }
        }
        let outcome = state.endPress()
        gestureStates[source] = state
        if outcome == .shortPress {
            perform(mapping(for: source).shortPress, source: source, gestureName: L("短押し"))
        }
        if wasLongPress {
            heldSources.remove(source)
            appendLog(L("%@: 押しっぱなし終了", source.displayName))
        } else {
            appendLog(L("%@: 解放を検出", source.displayName))
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
            perform(value.longPress, source: source, gestureName: L("押しっぱなし開始"))
        case .scroll:
            let movement = gestureMovement[source] ?? .zero
            gestureMovement[source] = .zero
            stopMomentum()
            scrollVelocity = .zero
            ActionPerformer.scroll(deltaX: movement.x, deltaY: movement.y, settings: scrollSettings)
            appendLog(L("%@: スクロールモード開始", source.displayName))
        case .directions:
            CursorFreeze.freeze()
            appendLog(L("%@: 方向ジェスチャー開始（カーソル固定）", source.displayName))
            triggerDirectionalGestureIfNeeded(for: source)
        }
    }

    /// Scroll and direction modes need trackball movement while the button is
    /// held. Motion is only taken over for those modes, so a plain action
    /// mapping still moves the cursor normally.
    private func routeMotion(for source: ButtonSource, pressed: Bool) {
        guard mapping(for: source).longPressMode != .action else {
            mouse.setExternallyHeld(source, held: false)
            return
        }
        mouse.setExternallyHeld(source, held: pressed && effectiveEnabled)
    }

    /// Wheel input: keep the latest speed and glide once the wheel stops.
    private func handleWheel(deltaY: Double, deltaX: Double) {
        guard effectiveEnabled, scrollSettings.momentumEnabled else { return }
        cancelMomentumTimer()
        scrollVelocity.x = scrollVelocity.x * 0.6 + deltaX * 0.4
        scrollVelocity.y = scrollVelocity.y * 0.6 + deltaY * 0.4
        wheelIdleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.startWheelMomentum()
        }
        wheelIdleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wheelIdleSeconds, execute: workItem)
    }

    private func startWheelMomentum() {
        wheelIdleWorkItem = nil
        guard scrollSettings.momentumEnabled, effectiveEnabled else { return }
        scrollVelocity.x *= scrollSettings.momentumBoost
        scrollVelocity.y *= scrollSettings.momentumBoost
        guard hypot(scrollVelocity.x, scrollVelocity.y) >= ScrollSettings.momentumStopSpeed else {
            scrollVelocity = .zero
            return
        }
        appendLog(L("ホイール: 慣性スクロール開始"))
        startMomentumTimer()
    }

    private func startMomentumIfNeeded(for source: ButtonSource) {
        // Only the timer is cancelled here: the velocity built up during the
        // drag is exactly what the glide needs.
        cancelMomentumTimer()
        guard scrollSettings.momentumEnabled else { return }
        let speed = hypot(scrollVelocity.x, scrollVelocity.y)
        guard speed >= ScrollSettings.momentumStopSpeed else {
            scrollVelocity = .zero
            return
        }
        scrollVelocity.x *= scrollSettings.momentumBoost
        scrollVelocity.y *= scrollSettings.momentumBoost
        appendLog(L("%@: 慣性スクロール開始", source.displayName))
        startMomentumTimer()
    }

    private func startMomentumTimer() {
        let timer = Timer(timeInterval: ScrollSettings.momentumTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceMomentum() }
        }
        momentumTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceMomentum() {
        let friction = scrollSettings.momentumFriction
        scrollVelocity.x *= friction
        scrollVelocity.y *= friction
        guard hypot(scrollVelocity.x, scrollVelocity.y) >= ScrollSettings.momentumStopSpeed else {
            stopMomentum()
            return
        }
        ActionPerformer.postScroll(deltaX: scrollVelocity.x, deltaY: scrollVelocity.y)
    }

    private static let wheelIdleSeconds: Double = 0.08

    private func cancelMomentumTimer() {
        wheelIdleWorkItem?.cancel()
        wheelIdleWorkItem = nil
        momentumTimer?.invalidate()
        momentumTimer = nil
    }

    private func stopMomentum() {
        cancelMomentumTimer()
        scrollVelocity = .zero
    }

    private func handleMotion(source: ButtonSource, deltaX: Double, deltaY: Double) {
        guard let state = gestureStates[source], state.isPressed else { return }
        let mode = mapping(for: source).longPressMode
        if state.didTriggerLongPress, mode == .scroll {
            ActionPerformer.scroll(deltaX: deltaX, deltaY: deltaY, settings: scrollSettings)
            // Smoothed so a single jittery sample cannot define the throw.
            scrollVelocity.x = scrollVelocity.x * 0.7 + deltaX * 0.3
            scrollVelocity.y = scrollVelocity.y * 0.7 + deltaY * 0.3
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
        perform(action, source: source, gestureName: L("押しっぱなし + %@", direction.displayName))
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
            self.appendLog(L("%@: 次の方向操作を待機", source.displayName))
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
        if action == .switchDevice {
            appendLog(hid.switchToNextHost())
            return
        }
        guard action == .none || CGPreflightPostEventAccess() else {
            appendLog(L("操作を送信できません: アクセシビリティの許可を確認してください"))
            return
        }
        if let report = ActionPerformer.perform(action) {
            appendLog(report)
        }
    }

    private func resetButtonGesture() {
        CursorFreeze.release()
        stopMomentum()
        for workItem in longPressWorkItems.values { workItem.cancel() }
        for workItem in directionalCooldownWorkItems.values { workItem.cancel() }
        longPressWorkItems.removeAll()
        directionalCooldownWorkItems.removeAll()
        gestureStates.removeAll()
        gestureMovement.removeAll()
        heldSources.removeAll()
        triggeredDirectionalSources.removeAll()
    }

    /// Reused: building a DateFormatter per line is wasteful on a path that
    /// runs several times per button press.
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let logQueue = DispatchQueue(label: "com.elgotune.log", qos: .utility)

    private func appendLog(_ line: String) {
        let entry = "\(Self.logTimeFormatter.string(from: Date()))  \(line)"
        logLines.append(entry)
        if logLines.count > 80 { logLines.removeFirst(logLines.count - 80) }
        // Writing here would block the button press for up to 12 ms per line.
        Self.logQueue.async { Self.writeToLogFile(entry) }
    }

    /// Mirrors the in-window log to ~/Library/Logs so device detection can be
    /// inspected after the fact.
    static let logFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Elgotune.log")

    private static func writeToLogFile(_ entry: String) {
        guard let data = (entry + "\n").data(using: .utf8) else { return }
        let url = logFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url)
        }
    }

    /// Pre-builds the CGEvents the current assignments need. On macOS 27 the
    /// first build of each key costs milliseconds, and that would land on the
    /// very first press.
    private func warmUpKeyEvents() {
        var keyCodes: Set<CGKeyCode> = [126, 125, 103, 36, 51]
        for mapping in mappings.values {
            for action in [mapping.shortPress, mapping.longPress] + Array(mapping.directionalActions.values) {
                if case .shortcut(let shortcut) = action { keyCodes.insert(CGKeyCode(shortcut.keyCode)) }
            }
        }
        ActionPerformer.warmUp(keyCodes: keyCodes)
    }

    private func saveMappings() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "buttonMappings")
        }
    }

    private func updateMouseCapture() {
        let customized = Set(ButtonSource.allCases.filter { source in
            guard effectiveEnabled else { return false }
            let value = mapping(for: source)
            return value.shortPress != source.nativeAction || value.longPress != .none || value.longPressMode != .action
        })
        mouse.setCapturedSources(customized.intersection([.left, .right, .middle]))
        hid.setCustomizedSources(customized)
    }
}

/// Everything the user configures, in one file for backup or transfer.
struct SettingsBundle: Codable {
    var version = 1
    var mappings: [ButtonSource: ButtonMapping]
    var longPressMilliseconds: Double
    var excludedApps: [ExcludedApp]
    var scrollSettings: ScrollSettings

    private enum CodingKeys: String, CodingKey {
        case version, mappings, longPressMilliseconds, excludedApps, scrollSettings
    }

    init(
        mappings: [ButtonSource: ButtonMapping],
        longPressMilliseconds: Double,
        excludedApps: [ExcludedApp],
        scrollSettings: ScrollSettings = ScrollSettings()
    ) {
        self.mappings = mappings
        self.longPressMilliseconds = longPressMilliseconds
        self.excludedApps = excludedApps
        self.scrollSettings = scrollSettings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        // Keyed by raw value so the file stays a readable JSON object; the
        // UserDefaults copy keeps its own legacy encoding.
        try container.encode(
            Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value) }),
            forKey: .mappings
        )
        try container.encode(longPressMilliseconds, forKey: .longPressMilliseconds)
        try container.encode(excludedApps, forKey: .excludedApps)
        try container.encode(scrollSettings, forKey: .scrollSettings)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let rawMappings = try container.decode([String: ButtonMapping].self, forKey: .mappings)
        mappings = Dictionary(uniqueKeysWithValues: rawMappings.compactMap { key, value in
            ButtonSource(rawValue: key).map { ($0, value) }
        })
        let milliseconds = try container.decodeIfPresent(Double.self, forKey: .longPressMilliseconds) ?? 600
        longPressMilliseconds = min(max(milliseconds, 100), 1_500)
        excludedApps = try container.decodeIfPresent([ExcludedApp].self, forKey: .excludedApps) ?? []
        scrollSettings = try container.decodeIfPresent(ScrollSettings.self, forKey: .scrollSettings) ?? ScrollSettings()
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
    var supportsHostSwitch: Bool = false
}

enum LogitechBatteryState: Equatable {
    case discharging
    case charging
    case full
    case error
    case unknown

    var displayName: String {
        switch self {
        case .discharging: L("使用中")
        case .charging: L("充電中")
        case .full: L("充電完了")
        case .error: L("充電エラー")
        case .unknown: L("状態不明")
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
        case .critical: L("危険")
        case .low: L("少ない")
        case .good: L("良好")
        case .full: L("満充電")
        case .unknown: L("不明")
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
        return L("取得中…")
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
