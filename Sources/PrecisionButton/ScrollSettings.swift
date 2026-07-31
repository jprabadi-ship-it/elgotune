import Foundation

/// Tuning for the press-and-drag scroll mode.
struct ScrollSettings: Codable, Equatable {
    /// Extra speed on top of 1x: 0 keeps the system-like default pace.
    var speed: Double = 0
    /// 1 keeps scrolling linear; higher values make fast flicks travel farther.
    var acceleration: Double = 1
    var invertVertical = false
    var invertHorizontal = false
    var momentumEnabled = true
    /// Per-tick velocity retention: higher glides longer.
    var momentumFriction: Double = 0.94
    /// Extra kick given to the throw the moment the button is released.
    var momentumBoost: Double = 1

    static let momentumTickSeconds: Double = 1.0 / 60.0
    /// Below this pixel-per-tick speed the glide is imperceptible.
    static let momentumStopSpeed: Double = 0.4
    static let speedRange: ClosedRange<Double> = 0...128
    static let accelerationRange: ClosedRange<Double> = 1...10
    static let frictionRange: ClosedRange<Double> = 0.80...0.999
    static let boostRange: ClosedRange<Double> = 1...8

    /// Movement is measured against this per-event distance before the
    /// acceleration curve decides to boost or damp it.
    private static let referenceDistance: Double = 8
    private static let accelerationGainRange: ClosedRange<Double> = 0.3...12

    /// 0 is 1x and the top of the slider reaches about 13x, since a trackball
    /// ball rotation covers far less distance than a mouse sweep.
    var multiplier: Double { 1 + speed / 10 }

    /// Gain for one motion sample of the given magnitude.
    func gain(forDistance distance: Double) -> Double {
        guard acceleration > 1, distance > 0 else { return multiplier }
        let exponent = (acceleration - 1) * 0.25
        let raw = pow(distance / Self.referenceDistance, exponent)
        return multiplier * raw.clamped(to: Self.accelerationGainRange)
    }

    private enum CodingKeys: String, CodingKey {
        case speed, acceleration, sensitivity, invertVertical, invertHorizontal
        case momentumEnabled, momentumFriction, momentumBoost
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawSpeed = try container.decodeIfPresent(Double.self, forKey: .speed) {
            speed = rawSpeed.clamped(to: Self.speedRange)
        } else if let legacySensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) {
            // Settings saved before speed/acceleration split.
            speed = ((legacySensitivity - 1) * 10).clamped(to: Self.speedRange)
        }
        let rawAcceleration = try container.decodeIfPresent(Double.self, forKey: .acceleration) ?? 1
        acceleration = rawAcceleration.clamped(to: Self.accelerationRange)
        invertVertical = try container.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? false
        invertHorizontal = try container.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? false
        momentumEnabled = try container.decodeIfPresent(Bool.self, forKey: .momentumEnabled) ?? true
        let rawFriction = try container.decodeIfPresent(Double.self, forKey: .momentumFriction) ?? 0.94
        momentumFriction = rawFriction.clamped(to: Self.frictionRange)
        let rawBoost = try container.decodeIfPresent(Double.self, forKey: .momentumBoost) ?? 1
        momentumBoost = rawBoost.clamped(to: Self.boostRange)
    }

    /// Roughly how long a brisk throw keeps gliding, for display only.
    var estimatedGlideSeconds: Double {
        let startSpeed = 20 * momentumBoost
        guard momentumFriction < 1, startSpeed > Self.momentumStopSpeed else { return 0 }
        let ticks = log(Self.momentumStopSpeed / startSpeed) / log(momentumFriction)
        return ticks * Self.momentumTickSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speed, forKey: .speed)
        try container.encode(acceleration, forKey: .acceleration)
        try container.encode(invertVertical, forKey: .invertVertical)
        try container.encode(invertHorizontal, forKey: .invertHorizontal)
        try container.encode(momentumEnabled, forKey: .momentumEnabled)
        try container.encode(momentumFriction, forKey: .momentumFriction)
        try container.encode(momentumBoost, forKey: .momentumBoost)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
