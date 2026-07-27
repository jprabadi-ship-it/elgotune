import AppKit
import CoreGraphics
import Foundation

/// Captures a shortcut before macOS consumes system combinations such as Control+Up.
final class ShortcutCaptureMonitor: @unchecked Sendable {
    var onShortcut: ((KeyboardShortcut) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutCaptureCallback,
            userInfo: context
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        onShortcut?(Self.shortcut(from: event))
        return nil
    }

    static func shortcut(from event: CGEvent) -> KeyboardShortcut {
        let cgFlags = event.flags
        var modifiers: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) { modifiers.insert(.command) }
        if cgFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if cgFlags.contains(.maskControl) { modifiers.insert(.control) }
        if cgFlags.contains(.maskShift) { modifiers.insert(.shift) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        return KeyboardShortcut(keyCode: keyCode, modifiers: modifiers.rawValue, characters: characters)
    }
}

private let shortcutCaptureCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ShortcutCaptureMonitor>.fromOpaque(userInfo).takeUnretainedValue().process(type: type, event: event)
}
