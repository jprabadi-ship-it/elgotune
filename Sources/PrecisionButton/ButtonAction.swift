import AppKit
import CoreGraphics

enum ButtonSource: String, Codable, CaseIterable, Hashable, Identifiable {
    case precision
    case left
    case right
    case back
    case forward

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .precision: "精密モード"
        case .left: "左クリック"
        case .right: "右クリック"
        case .back: "戻る"
        case .forward: "進む"
        }
    }

    var nativeAction: ButtonAction {
        switch self {
        case .precision: .missionControl
        case .left: .leftClick
        case .right: .rightClick
        case .back: .backClick
        case .forward: .forwardClick
        }
    }
}

enum LongPressMode: String, Codable, CaseIterable, Identifiable {
    case action
    case scroll
    case directions

    var id: String { rawValue }
}

enum GestureDirection: String, Codable, CaseIterable, Hashable, Identifiable {
    case up
    case down
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .up: "上 ↑"
        case .down: "下 ↓"
        case .left: "左 ←"
        case .right: "右 →"
        }
    }

    static func dominant(deltaX: Double, deltaY: Double, minimumDistance: Double = 24) -> GestureDirection? {
        guard hypot(deltaX, deltaY) >= minimumDistance else { return nil }
        if abs(deltaX) > abs(deltaY) { return deltaX < 0 ? .left : .right }
        return deltaY < 0 ? .up : .down
    }
}

struct ButtonMapping: Codable, Equatable {
    var shortPress: ButtonAction
    var longPress: ButtonAction
    var longPressMode: LongPressMode
    var directionalActions: [GestureDirection: ButtonAction]

    init(
        shortPress: ButtonAction,
        longPress: ButtonAction,
        longPressMode: LongPressMode = .action,
        directionalActions: [GestureDirection: ButtonAction] = [:]
    ) {
        self.shortPress = shortPress
        self.longPress = longPress
        self.longPressMode = longPressMode
        self.directionalActions = directionalActions
    }

    private enum CodingKeys: String, CodingKey {
        case shortPress, longPress, longPressMode, directionalActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortPress = try container.decode(ButtonAction.self, forKey: .shortPress)
        longPress = try container.decode(ButtonAction.self, forKey: .longPress)
        longPressMode = try container.decodeIfPresent(LongPressMode.self, forKey: .longPressMode) ?? .action
        directionalActions = try container.decodeIfPresent([GestureDirection: ButtonAction].self, forKey: .directionalActions) ?? [:]
    }

    func action(for direction: GestureDirection) -> ButtonAction {
        directionalActions[direction] ?? .none
    }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String

    var displayName: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel)
        return parts.joined()
    }

    var keyLabel: String {
        switch keyCode {
        case 36: "↩"       // Return
        case 76: "⌤"       // Numeric keypad Enter
        case 48: "⇥"       // Tab
        case 49: "Space"
        case 51: "⌫"
        case 53: "⎋"
        case 117: "⌦"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: characters.isEmpty ? "Key \(keyCode)" : characters.uppercased()
        }
    }
}

enum ButtonAction: Codable, Equatable, Identifiable, CaseIterable {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case middleClick
    case returnKey
    case commandBackspace
    case leftClick
    case rightClick
    case backClick
    case forwardClick
    case shortcut(KeyboardShortcut)

    static var allCases: [ButtonAction] {
        [.none, .missionControl, .appExpose, .showDesktop, .leftClick, .rightClick, .middleClick, .backClick, .forwardClick, .returnKey, .commandBackspace, .shortcut(.init(keyCode: 35, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, characters: "P"))]
    }

    var id: String {
        switch self {
        case .none: "none"
        case .missionControl: "missionControl"
        case .appExpose: "appExpose"
        case .showDesktop: "showDesktop"
        case .middleClick: "middleClick"
        case .returnKey: "returnKey"
        case .commandBackspace: "commandBackspace"
        case .leftClick: "leftClick"
        case .rightClick: "rightClick"
        case .backClick: "backClick"
        case .forwardClick: "forwardClick"
        case .shortcut: "shortcut"
        }
    }

    var displayName: String {
        switch self {
        case .none: "なし"
        case .missionControl: "Mission Control"
        case .appExpose: "アプリケーションウインドウ"
        case .showDesktop: "デスクトップを表示"
        case .middleClick: "中央クリック"
        case .returnKey: "Enterキー"
        case .commandBackspace: "Command + Backspace（⌘⌫）"
        case .leftClick: "左クリック"
        case .rightClick: "右クリック"
        case .backClick: "戻る"
        case .forwardClick: "進む"
        case .shortcut(let value): "キーボードショートカット（\(value.displayName)）"
        }
    }
}

enum ButtonGestureOutcome: Equatable {
    case none
    case shortPress
    case longPress
}

struct ButtonGestureState {
    private(set) var isPressed = false
    private(set) var didTriggerLongPress = false

    mutating func beginPress() -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        didTriggerLongPress = false
        return true
    }

    mutating func reachLongPressThreshold() -> ButtonGestureOutcome {
        guard isPressed, !didTriggerLongPress else { return .none }
        didTriggerLongPress = true
        return .longPress
    }

    mutating func endPress() -> ButtonGestureOutcome {
        guard isPressed else { return .none }
        isPressed = false
        if didTriggerLongPress {
            didTriggerLongPress = false
            return .none
        }
        return .shortPress
    }

    mutating func reset() {
        isPressed = false
        didTriggerLongPress = false
    }
}

enum ActionPerformer {
    @discardableResult
    static func perform(_ action: ButtonAction) -> String? {
        switch action {
        case .none:
            return nil
        case .missionControl:
            return keyPress(keyCode: 126, flags: .maskControl)
        case .appExpose:
            return keyPress(keyCode: 125, flags: .maskControl)
        case .showDesktop:
            return keyPress(keyCode: 103, flags: []) // F11 (macOS default Show Desktop)
        case .middleClick:
            mouseClick(button: .center, down: .otherMouseDown, up: .otherMouseUp)
            return nil
        case .returnKey:
            return keyPress(keyCode: 36, flags: [])
        case .commandBackspace:
            return keyPress(keyCode: 51, flags: .maskCommand)
        case .leftClick:
            mouseClick(button: .left, down: .leftMouseDown, up: .leftMouseUp)
            return nil
        case .rightClick:
            mouseClick(button: .right, down: .rightMouseDown, up: .rightMouseUp)
            return nil
        case .backClick:
            mouseClick(button: CGMouseButton(rawValue: 3)!, down: .otherMouseDown, up: .otherMouseUp)
            return nil
        case .forwardClick:
            mouseClick(button: CGMouseButton(rawValue: 4)!, down: .otherMouseDown, up: .otherMouseUp)
            return nil
        case .shortcut(let shortcut):
            return keyPress(keyCode: CGKeyCode(shortcut.keyCode), flags: cgFlags(from: shortcut.modifiers))
        }
    }

    private static func mouseClick(button: CGMouseButton, down: CGEventType, up: CGEventType) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: location, mouseButton: button),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: location, mouseButton: button) else { return }
        downEvent.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        upEvent.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    static func scroll(deltaX: Double, deltaY: Double) {
        let scale = 1.8
        let vertical = clampedInt32(-deltaY * scale)
        let horizontal = clampedInt32(-deltaX * scale)
        guard vertical != 0 || horizontal != 0,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
              ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        event.post(tap: .cghidEventTap)
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }

    private static func keyPress(keyCode: CGKeyCode, flags: CGEventFlags) -> String {
        // This app acts like a user-space input driver: it translates a mouse
        // control into keyboard input, so inject the result at the HID entry.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return "キーイベント生成失敗 (code=\(keyCode))"
        }

        source.localEventsSuppressionInterval = 0

        let effectiveFlags = keyboardFlags(for: keyCode, modifiers: flags)

        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, 59),
            (.maskAlternate, 58),
            (.maskShift, 56),
            (.maskCommand, 55)
        ].filter { flags.contains($0.0) }
        var activeFlags: CGEventFlags = []
        for (flag, modifierKey) in modifierKeys {
            activeFlags.insert(flag)
            guard let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: true) else { continue }
            modifierDown.flags = activeFlags
            modifierDown.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
            modifierDown.post(tap: .cghidEventTap)
        }

        down.flags = effectiveFlags
        up.flags = effectiveFlags
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        for (flag, modifierKey) in modifierKeys.reversed() {
            activeFlags.remove(flag)
            guard let modifierUp = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: false) else { continue }
            modifierUp.flags = activeFlags
            modifierUp.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
            modifierUp.post(tap: .cghidEventTap)
        }

        return String(format: "キー送信: code=%u flags=0x%llx tap=HID", keyCode, effectiveFlags.rawValue)
    }

    static func keyboardFlags(for keyCode: CGKeyCode, modifiers: CGEventFlags) -> CGEventFlags {
        var result = modifiers
        // Apple's arrow keys carry SecondaryFn (0x800000). macOS stores that
        // bit in symbolic shortcuts such as Mission Control (Control+Up), so
        // synthesized arrows must include it for the system shortcut to match.
        if (123...126).contains(keyCode) { result.insert(.maskSecondaryFn) }
        return result
    }

    private static func cgFlags(from rawValue: UInt) -> CGEventFlags {
        let flags = NSEvent.ModifierFlags(rawValue: rawValue)
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }
}

enum SyntheticEvent {
    static let marker: Int64 = 0x5052_4543_4953_494F // "PRECISIO"
}
