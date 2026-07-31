import Foundation

/// Per-device pointer tuning through IOHIDEventSystemClient.
///
/// The public `NXEventStatus` acceleration is not honoured by connected
/// devices on current macOS, so the values have to be written onto the HID
/// service itself. These symbols are private, hence the dlsym lookup: if a
/// future macOS drops them, every call degrades to a no-op instead of
/// failing to launch.
enum PointerControl {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> CFArray?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> CFTypeRef?
    private typealias SetPropertyFn = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> Bool

    /// Resolution in DPI that macOS assigns by default; pointer speed scales it.
    static let defaultResolution: Double = 400
    /// speed 0.069 must reproduce the stock 400 DPI, so this is 400 * 0.069.
    static let resolutionConstant: Double = 27.6

    private static let logitechVendorID = 0x046D
    private static let mouseUsagePage = 1
    private static let mouseUsage = 2

    private struct Symbols: @unchecked Sendable {
        let create: CreateFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let setProperty: SetPropertyFn
        let client: CFTypeRef
    }

    private nonisolated(unsafe) static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func lookup<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create = lookup("IOHIDEventSystemClientCreate", CreateFn.self),
              let copyServices = lookup("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = lookup("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let setProperty = lookup("IOHIDServiceClientSetProperty", SetPropertyFn.self),
              let client = create(kCFAllocatorDefault) else { return nil }
        return Symbols(
            create: create,
            copyServices: copyServices,
            copyProperty: copyProperty,
            setProperty: setProperty,
            client: client
        )
    }()

    static var isAvailable: Bool { symbols != nil }

    /// IOFixed is a 16.16 fixed-point value.
    private static func fixed(_ value: Double) -> Int {
        Int((value * 65536).rounded())
    }

    private static func pointingServices() -> [CFTypeRef] {
        guard let symbols, let services = symbols.copyServices(symbols.client) as? [CFTypeRef] else { return [] }
        return services.filter { service in
            symbols.copyProperty(service, "VendorID" as CFString) as? Int == logitechVendorID
                && symbols.copyProperty(service, "PrimaryUsagePage" as CFString) as? Int == mouseUsagePage
                && symbols.copyProperty(service, "PrimaryUsage" as CFString) as? Int == mouseUsage
        }
    }

    /// Applies speed and acceleration to every connected Logitech pointer.
    /// Returns how many devices accepted the values.
    @discardableResult
    static func apply(_ settings: PointerSettings) -> Int {
        guard let symbols else { return 0 }
        let resolution = resolutionConstant / max(settings.speed, 0.005)
        var applied = 0
        for service in pointingServices() {
            let resolutionOK = symbols.setProperty(
                service,
                "HIDPointerResolution" as CFString,
                fixed(resolution) as CFNumber
            )
            // The service names which key its curve reads from.
            let accelerationKey = (symbols.copyProperty(service, "HIDPointerAccelerationType" as CFString) as? String)
                ?? "HIDMouseAcceleration"
            let accelerationOK = symbols.setProperty(
                service,
                accelerationKey as CFString,
                fixed(settings.acceleration) as CFNumber
            )
            if resolutionOK || accelerationOK { applied += 1 }
        }
        return applied
    }

    /// Current values of the first matching device, for display and diagnosis.
    static func currentValues() -> (resolution: Double, acceleration: Double)? {
        guard let symbols, let service = pointingServices().first else { return nil }
        let accelerationKey = (symbols.copyProperty(service, "HIDPointerAccelerationType" as CFString) as? String)
            ?? "HIDMouseAcceleration"
        guard let resolution = symbols.copyProperty(service, "HIDPointerResolution" as CFString) as? Int,
              let acceleration = symbols.copyProperty(service, accelerationKey as CFString) as? Int else { return nil }
        return (Double(resolution) / 65536, Double(acceleration) / 65536)
    }
}
