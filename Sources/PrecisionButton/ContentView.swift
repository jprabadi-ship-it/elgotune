import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSource: ButtonSource = .precision
    @State private var selectedTab: Tab = .buttons
    @State private var showOnboarding = false
    private let batteryRefresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum Tab: String, Hashable, CaseIterable, Identifiable {
        case buttons, pointer, scroll, excluded, backup, general, log

        var id: String { rawValue }

        var title: String {
            switch self {
            case .buttons: L("ボタン割り当て")
            case .pointer: L("ポインタ")
            case .scroll: L("スクロール")
            case .excluded: L("除外アプリ")
            case .backup: L("バックアップ")
            case .general: L("一般")
            case .log: L("診断ログ")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statusCard

            // A segmented picker rather than TabView: macOS lifts a TabView's
            // tab bar into the title bar, away from the content it switches.
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Group {
                    switch selectedTab {
                    case .buttons: actionCard
                    case .pointer: pointerCard
                    case .scroll: scrollCard
                    case .excluded: excludedAppsCard
                    case .backup: settingsFileCard
                    case .general: generalCard
                    case .log: diagnostics
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshBattery()
        }
        .onReceive(batteryRefresh) { _ in model.refreshBattery() }
        .onAppear { showOnboarding = model.shouldShowOnboarding }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(model)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("ErgoTune")
                    .font(.largeTitle.bold())
                Text(L("MX ERGO / ERGO M575 のボタンを、好きな操作に変えます。"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(L("有効"), isOn: $model.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.statusText, systemImage: model.deviceDetected ? "checkmark.circle.fill" : "magnifyingglass")
                        .foregroundStyle(model.deviceDetected ? .green : .secondary)
                    Spacer()
                    let batteries = model.deviceBatteries
                    if batteries.isEmpty, model.deviceDetected {
                        Label(L("バッテリーを取得中…"), systemImage: "battery.0percent")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(batteries, id: \.name) { entry in
                            Label(
                                batteries.count > 1 ? "\(entry.name) \(entry.battery.valueText)" : entry.battery.displayText,
                                systemImage: entry.battery.systemImage
                            )
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(entry.battery.level == .critical ? .red : .primary)
                        }
                    }
                }

                HStack(spacing: 16) {
                    permissionLabel(L("アクセシビリティ"), granted: model.accessibilityGranted)
                    permissionLabel(L("操作送信"), granted: model.eventPostingGranted)
                    permissionLabel(L("入力監視"), granted: model.inputMonitoringGranted)
                    Spacer()
                    if !model.accessibilityGranted || !model.eventPostingGranted || !model.inputMonitoringGranted {
                        Button(L("権限を許可…")) { model.requestPermissions() }
                    }
                    Button(L("再スキャン")) { model.rescan() }
                }
            }
            .padding(6)
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L("対象ボタン"), selection: $selectedSource) {
                    ForEach(model.availableSources) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.availableSources) { _, sources in
                    // Keep the selection on a button the connected device has.
                    if !sources.contains(selectedSource), let first = sources.first {
                        selectedSource = first
                    }
                }

                let mapping = mappingBinding(for: selectedSource)
                ActionPicker(title: L("短押し"), action: Binding(
                    get: { mapping.wrappedValue.shortPress },
                    set: { mapping.wrappedValue.shortPress = $0 }
                ))
                LongPressEditor(mapping: mapping)

                HStack {
                    Text(L("押しっぱなし開始"))
                    Slider(value: $model.longPressMilliseconds, in: 100...1_500, step: 50)
                    Text("\(Int(model.longPressMilliseconds)) ms")
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                    Button(L("標準に戻す")) {
                        model.setMapping(ButtonMapping(shortPress: selectedSource.nativeAction, longPress: .none), for: selectedSource)
                    }
                }
                .font(.caption)

                if model.heldSources.contains(selectedSource) {
                    Label(L("%@：押しっぱなし中", selectedSource.displayName), systemImage: "hand.point.up.left.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }

                if selectedSource == .left || selectedSource == .right || selectedSource == .middle {
                    Label(L("カスタマイズ中は、そのボタンの通常ドラッグがトラックボール操作へ置き換わります。"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if selectedSource == .tiltLeft || selectedSource == .tiltRight {
                    Label(L("「なし」のままならホイールチルト本来の横スクロールが働きます。割り当てると横スクロールは無効になります。"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if selectedSource == .deviceSwitch {
                    Label(L("「なし」のままなら本来のデバイス切り替えが働きます。割り当てを変えた場合でも、割り当て一覧の「デバイス切り替え」で元の切り替え動作を呼び出せます。"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var excludedAppsCard: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("ここに登録したアプリが最前面のとき、ボタンのカスタマイズは無効になり標準動作に戻ります。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.excludedApps.isEmpty {
                    Text(L("除外アプリは登録されていません。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(model.excludedApps) { app in
                            HStack {
                                Text(app.name)
                                Text(app.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .onDelete { model.removeExcludedApps(at: $0) }
                    }
                    .frame(height: min(CGFloat(model.excludedApps.count) * 28 + 8, 140))
                }

                HStack {
                    Menu(L("実行中のAppから追加…")) {
                        let candidates = model.excludableRunningApps()
                        if candidates.isEmpty {
                            Text(L("追加できるAppがありません"))
                        } else {
                            ForEach(candidates, id: \.bundleIdentifier) { candidate in
                                Button(candidate.name) {
                                    model.addExcludedApp(bundleIdentifier: candidate.bundleIdentifier, name: candidate.name)
                                }
                            }
                        }
                    }
                    Button(L("Appを選択…")) { presentAppPicker() }
                    if model.isFrontmostAppExcluded {
                        Label(L("現在のAppは除外中"), systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(6)
        }
    }

    private func presentAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addExcludedApp(at: url)
        }
    }

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(L("権限の設定ガイドを開く…")) { showOnboarding = true }
            Divider()

            Toggle(L("ログイン時に起動"), isOn: $model.launchAtLogin)
            Text(L("状態: %@", model.loginItemStatusText))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("初回は システム設定 > 一般 > ログイン項目 での承認が必要な場合があります。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text(model.versionText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("対応デバイス: MX ERGO / ERGO M575（M575S・M575SP を含む）"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
    }

    private var settingsFileCard: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L("ボタン割り当て・押しっぱなし判定・スクロール設定・除外アプリをJSONファイルで保存／復元します。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("エクスポート…")) { presentSettingsExport() }
                Button(L("インポート…")) { presentSettingsImport() }
            }
            .padding(6)
        }
    }

    private var pointerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("トラックボールでカーソルを動かすときの感触です。システム全体のポインタ加速（システム設定の「軌跡の速さ」と同じ値）を変更します。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(L("ポインタの加速"))
                Slider(
                    value: $model.pointerSettings.acceleration,
                    in: PointerSettings.accelerationRange,
                    step: 0.5
                )
                Text(String(format: "%.1f", model.pointerSettings.acceleration))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            Text(L("macOSの標準は 3 です。0 で加速なし＝等速になります。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(L("ポインタの速度"))
                Slider(
                    value: $model.pointerSettings.speed,
                    in: PointerSettings.speedRange,
                    step: 0.001
                )
                Text(String(format: "%.3f", model.pointerSettings.speed))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
                Text(String(format: "%.0f DPI", model.pointerSettings.resolution))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(L("標準は 0.069（400 DPI 相当）です。値を上げるほど速く、下げるほど遅くなります。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(model.systemAccelerationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("システムデフォルトに戻す")) { model.resetPointerToSystemDefault() }
            }
        }
        .padding(6)
    }

    private var scrollCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ホイールを回したときのスクロール量に適用されます。ボタンの押しっぱなし「スクロール」モードにも同じ設定が使われます。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(L("縦スクロールを反転"), isOn: $model.scrollSettings.invertVertical)
            Toggle(L("横スクロールを反転"), isOn: $model.scrollSettings.invertHorizontal)

            HStack {
                Text(L("スクロールの加速"))
                Slider(
                    value: $model.scrollSettings.acceleration,
                    in: ScrollSettings.accelerationRange,
                    step: 1
                )
                Text("\(Int(model.scrollSettings.acceleration))")
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            Text(L("標準は 1 で等速です。値を上げるほど、速く動かしたときに大きくスクロールします（最大10で、速い動きは最大12倍まで上乗せ）。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L("標準は 0 で、0 が等倍です。最大 128 で約13倍まで上がります。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(L("スクロールの速さ"))
                Slider(
                    value: $model.scrollSettings.speed,
                    in: ScrollSettings.speedRange,
                    step: 1
                )
                Text("\(Int(model.scrollSettings.speed))")
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
                Text(String(format: "×%.2f", model.scrollSettings.multiplier))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }

            Divider()

            Toggle(L("慣性スクロール"), isOn: $model.scrollSettings.momentumEnabled)
            Text(L("ホイールを止めたあとも、勢いに応じてスクロールが滑らかに減速しながら続きます。次にホイールを回すか、ボタンを押すと即座に止まります。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(L("滑りやすさ"))
                Slider(
                    value: $model.scrollSettings.momentumFriction,
                    in: ScrollSettings.frictionRange,
                    step: 0.001
                )
                Text(String(format: "%.3f", model.scrollSettings.momentumFriction))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            .disabled(!model.scrollSettings.momentumEnabled)

            HStack {
                Text(L("離したときの勢い"))
                Slider(
                    value: $model.scrollSettings.momentumBoost,
                    in: ScrollSettings.boostRange,
                    step: 0.1
                )
                Text(String(format: "×%.1f", model.scrollSettings.momentumBoost))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            .disabled(!model.scrollSettings.momentumEnabled)

            Text(String(format: L("0.999 まで上げると、はっきり分かるほど長く滑ります。目安の滑走時間: 約 %.1f 秒"), model.scrollSettings.estimatedGlideSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L("標準に戻す")) { model.scrollSettings = ScrollSettings() }
            }
        }
        .padding(6)
    }

    private func presentSettingsExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ErgoTune-Settings.json"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSettings(to: url)
        }
    }

    private func presentSettingsImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importSettings(from: url)
        }
    }

    private var diagnostics: some View {
        Text(model.logLines.isEmpty ? L("接続イベントを待機しています…") : model.logLines.joined(separator: "\n"))
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(6)
    }

    private func permissionLabel(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(granted ? .green : .orange)
    }

    private func mappingBinding(for source: ButtonSource) -> Binding<ButtonMapping> {
        Binding {
            model.mapping(for: source)
        } set: { value in
            model.setMapping(value, for: source)
        }
    }
}

private struct LongPressEditor: View {
    @Binding var mapping: ButtonMapping
    @State private var selectedDirection: GestureDirection = .up

    var body: some View {
        GroupBox(L("押しっぱなし")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L("モード"), selection: $mapping.longPressMode) {
                    Text(L("操作")).tag(LongPressMode.action)
                    Text(L("スクロール")).tag(LongPressMode.scroll)
                    Text(L("上下左右")).tag(LongPressMode.directions)
                }
                .pickerStyle(.segmented)

                switch mapping.longPressMode {
                case .action:
                    ActionPicker(title: L("開始時に実行する操作"), action: $mapping.longPress)
                case .scroll:
                    Label(L("押している間、トラックボール移動を縦横スクロールに変換します。"), systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                case .directions:
                    Picker(L("方向"), selection: $selectedDirection) {
                        ForEach(GestureDirection.allCases) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    ActionPicker(title: L("%@の操作", selectedDirection.displayName), action: directionAction)
                }
            }
            .padding(6)
        }
    }

    private var directionAction: Binding<ButtonAction> {
        Binding {
            mapping.action(for: selectedDirection)
        } set: { action in
            mapping.directionalActions[selectedDirection] = action
        }
    }
}

private struct ActionPicker: View {
    let title: String
    @Binding var action: ButtonAction

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L("割り当て"), selection: actionID) {
                    Text(L("なし")).tag("none")
                    Text("Mission Control").tag("missionControl")
                    Text(L("アプリケーションウインドウ")).tag("appExpose")
                    Text(L("デスクトップを表示")).tag("showDesktop")
                    Divider()
                    Text(L("左クリック")).tag("leftClick")
                    Text(L("右クリック")).tag("rightClick")
                    Text(L("中央クリック")).tag("middleClick")
                    Text(L("戻る")).tag("backClick")
                    Text(L("進む")).tag("forwardClick")
                    Text(L("左へスクロール")).tag("scrollLeft")
                    Text(L("右へスクロール")).tag("scrollRight")
                    Text(L("デバイス切り替え")).tag("switchDevice")
                    Divider()
                    Text(L("Enterキー")).tag("returnKey")
                    Text("Command + Backspace（⌘⌫）").tag("commandBackspace")
                    Text(L("キーボードショートカット")).tag("shortcut")
                }

                if case .shortcut(let shortcut) = action {
                    HStack {
                        Text(L("ショートカット"))
                        ShortcutRecorder(shortcut: shortcut) { action = .shortcut($0) }
                            .frame(width: 180, height: 28)
                        Text(L("欄をクリックしてキーを押してください"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private var actionID: Binding<String> {
        Binding {
            action.id
        } set: { id in
            switch id {
            case "none": action = .none
            case "missionControl": action = .missionControl
            case "appExpose": action = .appExpose
            case "showDesktop": action = .showDesktop
            case "middleClick": action = .middleClick
            case "leftClick": action = .leftClick
            case "rightClick": action = .rightClick
            case "backClick": action = .backClick
            case "forwardClick": action = .forwardClick
            case "scrollLeft": action = .scrollLeft
            case "scrollRight": action = .scrollRight
            case "switchDevice": action = .switchDevice
            case "returnKey": action = .returnKey
            case "commandBackspace": action = .commandBackspace
            default:
                if case .shortcut = action { return }
                action = .shortcut(.init(keyCode: 35, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, characters: "P"))
            }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut
    let onChange: (KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = onChange
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = onChange
        view.shortcut = shortcut
        view.needsDisplay = true
    }
}

final class ShortcutRecorderView: NSView {
    var shortcut: KeyboardShortcut = .init(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
    var onChange: ((KeyboardShortcut) -> Void)?
    private var recording = false
    private var keyMonitor: Any?
    private let systemKeyCapture = ShortcutCaptureMonitor()

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        beginMonitoringKeys()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        let allowed = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers ?? ""
        // Return and keypad Enter can arrive without a printable character.
        guard !chars.isEmpty || event.keyCode == 36 || event.keyCode == 76 else { return }
        accept(KeyboardShortcut(keyCode: event.keyCode, modifiers: allowed.rawValue, characters: chars))
    }

    private func accept(_ captured: KeyboardShortcut) {
        guard recording else { return }
        shortcut = captured
        recording = false
        endMonitoringKeys()
        onChange?(shortcut)
        needsDisplay = true
    }

    private func beginMonitoringKeys() {
        endMonitoringKeys()
        systemKeyCapture.onShortcut = { [weak self] shortcut in
            DispatchQueue.main.async { self?.accept(shortcut) }
        }
        _ = systemKeyCapture.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func endMonitoringKeys() {
        systemKeyCapture.stop()
        systemKeyCapture.onShortcut = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endMonitoringKeys() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? L("キーを入力…") : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
