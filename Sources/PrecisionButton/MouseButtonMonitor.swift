import CoreGraphics
import Foundation

final class MouseButtonMonitor: @unchecked Sendable {
    var onButton: ((ButtonSource, Bool) -> Void)?
    var onMotion: ((ButtonSource, Double, Double) -> Void)?
    var onLog: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var capturedSources: Set<ButtonSource> = []
    private var activeSources: Set<ButtonSource> = []

    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseEventCallback,
            userInfo: context
        ) else {
            onLog?("左右クリックの監視にはアクセシビリティ権限が必要です")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onLog?("左右クリックの監視を開始")
    }

    func setCapturedSources(_ sources: Set<ButtonSource>) {
        lock.lock()
        let released = activeSources.subtracting(sources)
        activeSources.subtract(released)
        capturedSources = sources
        lock.unlock()
        for source in released { onButton?(source, false) }
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker {
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            lock.lock()
            let active = ButtonSource.allCases.first(where: { activeSources.contains($0) })
            lock.unlock()
            guard let active else { return Unmanaged.passUnretained(event) }
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            onMotion?(active, dx, dy)
            return nil
        }

        let source: ButtonSource
        let pressed: Bool
        switch type {
        case .leftMouseDown:
            source = .left; pressed = true
        case .leftMouseUp:
            source = .left; pressed = false
        case .rightMouseDown:
            source = .right; pressed = true
        case .rightMouseUp:
            source = .right; pressed = false
        default:
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let shouldCapture = capturedSources.contains(source) || activeSources.contains(source)
        lock.unlock()
        guard shouldCapture else { return Unmanaged.passUnretained(event) }

        // Keep left click available inside our own UI so every customization can
        // always be restored. Right-click gestures may still be tested here.
        if source == .left, isInsideOwnWindow(event.location) {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        if pressed { activeSources.insert(source) } else { activeSources.remove(source) }
        lock.unlock()
        onButton?(source, pressed)
        return nil
    }

    private func isInsideOwnWindow(_ point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(kCGNullWindowID)
        ) as? [[String: Any]] else { return false }

        let ownPID = getpid()
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
    }
}

private let mouseEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseButtonMonitor>.fromOpaque(userInfo).takeUnretainedValue().process(type: type, event: event)
}
