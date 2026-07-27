import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSource: ButtonSource = .precision
    private let batteryRefresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statusCard
            actionCard
            excludedAppsCard
            diagnostics
        }
        .padding(24)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshBattery()
        }
        .onReceive(batteryRefresh) { _ in model.refreshBattery() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Precision Button")
                    .font(.largeTitle.bold())
                Text("MX ERGOの精密モードボタンを、好きな操作に変えます。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("有効", isOn: $model.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.statusText, systemImage: model.devices.contains(where: { $0.precisionControlID != nil }) ? "checkmark.circle.fill" : "magnifyingglass")
                        .foregroundStyle(model.devices.contains(where: { $0.precisionControlID != nil }) ? .green : .secondary)
                    Spacer()
                    if let battery = model.primaryBattery {
                        Label(battery.displayText, systemImage: battery.systemImage)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(battery.level == .critical ? .red : .primary)
                    } else if model.devices.contains(where: { $0.precisionControlID != nil }) {
                        Label("バッテリーを取得中…", systemImage: "battery.0percent")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    permissionLabel("アクセシビリティ", granted: model.accessibilityGranted)
                    permissionLabel("操作送信", granted: model.eventPostingGranted)
                    permissionLabel("入力監視", granted: model.inputMonitoringGranted)
                    Spacer()
                    if !model.accessibilityGranted || !model.eventPostingGranted || !model.inputMonitoringGranted {
                        Button("権限を許可…") { model.requestPermissions() }
                    }
                    Button("再スキャン") { model.rescan() }
                }
            }
            .padding(6)
        }
    }

    private var actionCard: some View {
        GroupBox("ボタン別割り当て") {
            VStack(spacing: 12) {
                Picker("対象ボタン", selection: $selectedSource) {
                    ForEach(ButtonSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                let mapping = mappingBinding(for: selectedSource)
                ActionPicker(title: "短押し", action: Binding(
                    get: { mapping.wrappedValue.shortPress },
                    set: { mapping.wrappedValue.shortPress = $0 }
                ))
                if selectedSource == .left || selectedSource == .right {
                    LongPressEditor(mapping: mapping)
                } else {
                    ActionPicker(title: "押しっぱなし開始時", action: Binding(
                        get: { mapping.wrappedValue.longPress },
                        set: {
                            mapping.wrappedValue.longPress = $0
                            mapping.wrappedValue.longPressMode = .action
                        }
                    ))
                }

                HStack {
                    Text("押しっぱなし開始")
                    Slider(value: $model.longPressMilliseconds, in: 100...1_500, step: 50)
                    Text("\(Int(model.longPressMilliseconds)) ms")
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                    Button("標準に戻す") {
                        model.setMapping(ButtonMapping(shortPress: selectedSource.nativeAction, longPress: .none), for: selectedSource)
                    }
                }
                .font(.caption)

                if model.heldSources.contains(selectedSource) {
                    Label("\(selectedSource.displayName)：押しっぱなし中", systemImage: "hand.point.up.left.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }

                if selectedSource == .left || selectedSource == .right {
                    Label("カスタマイズ中は、そのボタンの通常ドラッグがトラックボール操作へ置き換わります。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var excludedAppsCard: some View {
        GroupBox("除外アプリ") {
            VStack(alignment: .leading, spacing: 10) {
                Text("ここに登録したアプリが最前面のとき、ボタンのカスタマイズは無効になり標準動作に戻ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.excludedApps.isEmpty {
                    Text("除外アプリは登録されていません。")
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
                    Menu("実行中のAppから追加…") {
                        let candidates = model.excludableRunningApps()
                        if candidates.isEmpty {
                            Text("追加できるAppがありません")
                        } else {
                            ForEach(candidates, id: \.bundleIdentifier) { candidate in
                                Button(candidate.name) {
                                    model.addExcludedApp(bundleIdentifier: candidate.bundleIdentifier, name: candidate.name)
                                }
                            }
                        }
                    }
                    Button("Appを選択…") { presentAppPicker() }
                    if model.isFrontmostAppExcluded {
                        Label("現在のAppは除外中", systemImage: "pause.circle.fill")
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

    private var diagnostics: some View {
        GroupBox("診断ログ") {
            ScrollView {
                Text(model.logLines.isEmpty ? "接続イベントを待機しています…" : model.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(minHeight: 120)
        }
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
        GroupBox("押しっぱなし") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("モード", selection: $mapping.longPressMode) {
                    Text("操作").tag(LongPressMode.action)
                    Text("スクロール").tag(LongPressMode.scroll)
                    Text("上下左右").tag(LongPressMode.directions)
                }
                .pickerStyle(.segmented)

                switch mapping.longPressMode {
                case .action:
                    ActionPicker(title: "開始時に実行する操作", action: $mapping.longPress)
                case .scroll:
                    Label("押している間、トラックボール移動を縦横スクロールに変換します。", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                case .directions:
                    Picker("方向", selection: $selectedDirection) {
                        ForEach(GestureDirection.allCases) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    ActionPicker(title: "\(selectedDirection.displayName)の操作", action: directionAction)
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
                Picker("割り当て", selection: actionID) {
                    Text("なし").tag("none")
                    Text("Mission Control").tag("missionControl")
                    Text("アプリケーションウインドウ").tag("appExpose")
                    Text("デスクトップを表示").tag("showDesktop")
                    Divider()
                    Text("左クリック").tag("leftClick")
                    Text("右クリック").tag("rightClick")
                    Text("中央クリック").tag("middleClick")
                    Text("戻る").tag("backClick")
                    Text("進む").tag("forwardClick")
                    Divider()
                    Text("Enterキー").tag("returnKey")
                    Text("Command + Backspace（⌘⌫）").tag("commandBackspace")
                    Text("キーボードショートカット").tag("shortcut")
                }

                if case .shortcut(let shortcut) = action {
                    HStack {
                        Text("ショートカット")
                        ShortcutRecorder(shortcut: shortcut) { action = .shortcut($0) }
                            .frame(width: 180, height: 28)
                        Text("欄をクリックしてキーを押してください")
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
        let text = recording ? "キーを入力…" : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
