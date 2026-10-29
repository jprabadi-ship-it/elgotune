import CoreGraphics
import Foundation
import IOKit

/// Which pointing device a tap-handled button mapping listens to.
///
/// Devices outside the Logitech family speak no HID++, so the only way to
/// tell them apart is the HID service that sent each event.
enum DeviceScope: String, Codable, CaseIterable, Identifiable {
    case all
    case keychronT1HE

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: L("すべてのデバイス")
        case .keychronT1HE: "Keychron T1 HE"
        }
    }

    /// nil means every device, so there is nothing to look up.
    fileprivate var identity: (vendorID: Int, productID: Int)? {
        switch self {
        case .all: nil
        case .keychronT1HE: (0x3434, 0xD084)
        }
    }
}

enum PointerDevices {
    /// Undocumented: every mouse event carries the registry ID of the
    /// IOHIDEventService that produced it here. Measured on macOS 27 — a T1 HE
    /// right click reported 0x10002363A, exactly its service in `hidutil list`.
    static let senderField = CGEventField(rawValue: 87)!

    static func sender(of event: CGEvent) -> UInt64 {
        UInt64(bitPattern: event.getIntegerValueField(senderField))
    }

    /// Registry IDs of the pointer services that belong to `scope` right now.
    /// Empty when the device is not connected; nil for `.all`.
    static func serviceIDs(for scope: DeviceScope) -> Set<UInt64>? {
        guard let identity = scope.identity else { return nil }
        let matching = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = [
            "VendorID": identity.vendorID,
            "ProductID": identity.productID,
            "PrimaryUsagePage": 1,
            "PrimaryUsage": 2
        ]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: Set<UInt64> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
            IOObjectRelease(service)
        }
        return ids
    }
}
