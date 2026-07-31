import Foundation
import IOKit
import IOKit.hidsystem

/// Pointer feel. Acceleration is the system-wide HID curve; speed is applied by
/// this app to each motion event.
struct PointerSettings: Codable, Equatable {
    /// 0 disables the curve (linear tracking); macOS itself defaults to 3.
    var acceleration: Double = 3
    /// Scales the device's reported resolution: higher speed, fewer counts
    /// per inch, faster pointer.
    var speed: Double = 0.069

    static let accelerationRange: ClosedRange<Double> = 0...40
    static let speedRange: ClosedRange<Double> = 0...1
    static let neutralSpeed: Double = 0.069
    /// Never let the pointer stop entirely: the user needs it to undo this.
    private static let multiplierRange: ClosedRange<Double> = 0.05...20

    /// IOKit takes the same value macOS stores in com.apple.mouse.scaling.
    var systemAcceleration: Double { acceleration }

    var speedMultiplier: Double { (speed / Self.neutralSpeed).clamped(to: Self.multiplierRange) }

    /// The DPI value written to the device for this speed.
    var resolution: Double { PointerControl.resolutionConstant / Swift.max(speed, 0.005) }

    private enum CodingKeys: String, CodingKey {
        case acceleration, speed
    }

    init() {}

    init(acceleration: Double, speed: Double) {
        self.acceleration = acceleration.clamped(to: Self.accelerationRange)
        self.speed = speed.clamped(to: Self.speedRange)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAcceleration = try container.decodeIfPresent(Double.self, forKey: .acceleration) ?? 3
        acceleration = rawAcceleration.clamped(to: Self.accelerationRange)
        let rawSpeed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? Self.neutralSpeed
        speed = rawSpeed.clamped(to: Self.speedRange)
    }
}

/// Reads and writes the system pointer acceleration, the same value the
/// Trackpad/Mouse pane's tracking slider controls.
enum PointerAcceleration {
    private static var key: CFString { "HIDMouseAcceleration" as CFString }

    static func current() -> Double? {
        let handle = NXOpenEventStatus()
        guard handle != 0 else { return nil }
        defer { NXCloseEventStatus(handle) }
        var value: Double = 0
        guard IOHIDGetAccelerationWithKey(handle, key, &value) == KERN_SUCCESS else { return nil }
        return value
    }

    @discardableResult
    static func apply(_ value: Double) -> Bool {
        let handle = NXOpenEventStatus()
        guard handle != 0 else { return false }
        defer { NXCloseEventStatus(handle) }
        return IOHIDSetAccelerationWithKey(handle, key, value) == KERN_SUCCESS
    }
}
