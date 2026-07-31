import AppKit
import CoreGraphics

/// Pins the on-screen cursor while a directional gesture is in progress.
/// Motion events are still delivered to the event tap, so the gesture keeps
/// working while the pointer stays where the user left it.
@MainActor
enum CursorFreeze {
    private static var frozenAt: CGPoint?

    static var isFrozen: Bool { frozenAt != nil }

    static func freeze() {
        guard frozenAt == nil else { return }
        frozenAt = currentLocation()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    static func release() {
        guard let point = frozenAt else { return }
        frozenAt = nil
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Global (top-left origin) location of the cursor, matching CGWarp's space.
    private static func currentLocation() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first else { return mouse }
        return CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
    }
}
