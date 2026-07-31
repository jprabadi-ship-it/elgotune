import CoreGraphics
import Foundation

final class MouseButtonMonitor: @unchecked Sendable {
    var onButton: ((ButtonSource, Bool) -> Void)?
    var onMotion: ((ButtonSource, Double, Double) -> Void)?
    /// Scaled wheel movement, so momentum can be built from what apps saw.
    var onWheel: ((Double, Double) -> Void)?
    var onLog: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var capturedSources: Set<ButtonSource> = []
    private var activeSources: Set<ButtonSource> = []
    private var scrollSettings = ScrollSettings()

    func setScrollSettings(_ settings: ScrollSettings) {
        lock.lock()
        scrollSettings = settings
        lock.unlock()
    }

    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel
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
            onLog?(L("左右クリックの監視にはアクセシビリティ権限が必要です"))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onLog?(L("左右クリックの監視を開始"))
    }

    /// Buttons diverted over HID++ never reach this tap, so their press state
    /// has to be pushed in for trackball motion to be routed to them.
    func setExternallyHeld(_ source: ButtonSource, held: Bool) {
        lock.lock()
        if held { activeSources.insert(source) } else { activeSources.remove(source) }
        lock.unlock()
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

        if type == .scrollWheel {
            lock.lock()
            let settings = scrollSettings
            lock.unlock()
            return scaleWheel(event, with: settings)
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
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
        case .otherMouseDown, .otherMouseUp:
            // Button number 2 is the middle button; 3/4 are back/forward and
            // are handled through HID++ diversion instead.
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
                return Unmanaged.passUnretained(event)
            }
            source = .middle; pressed = type == .otherMouseDown
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

    /// Rescales a wheel event in place. Unlike pointer motion, a scroll event
    /// carries its whole meaning in these delta fields, so editing them is
    /// enough — nothing else has to be moved.
    private func scaleWheel(_ event: CGEvent, with settings: ScrollSettings) -> Unmanaged<CGEvent>? {
        let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let lineY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let lineX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)

        // Line-based wheels report no point delta, so fall back for the curve.
        let distance = max(hypot(pointX, pointY), hypot(lineX, lineY) * 10)
        let gain = settings.gain(forDistance: distance)
        let signY: Double = settings.invertVertical ? -1 : 1
        let signX: Double = settings.invertHorizontal ? -1 : 1
        guard gain != 1 || signY != 1 || signX != 1 else {
            onWheel?(pointY, pointX)
            return Unmanaged.passUnretained(event)
        }

        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pointY * gain * signY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: pointX * gain * signX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedY * gain * signY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedX * gain * signX)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: lineY * gain * signY)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: lineX * gain * signX)

        onWheel?(pointY * gain * signY, pointX * gain * signX)
        return Unmanaged.passUnretained(event)
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
