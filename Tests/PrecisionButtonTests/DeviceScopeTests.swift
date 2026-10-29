import Foundation
import Testing
@testable import PrecisionButton

@Test func mappingsSavedBeforeDeviceScopeDecodeAsAllDevices() throws {
    let legacy = #"{"shortPress":{"rightClick":{}},"longPress":{"none":{}},"longPressMode":"directions","directionalActions":[]}"#
    let mapping = try JSONDecoder().decode(ButtonMapping.self, from: Data(legacy.utf8))
    #expect(mapping.deviceScope == .all)
    #expect(mapping.longPressMode == .directions)
}

@Test func deviceScopeSurvivesRoundTrip() throws {
    let mapping = ButtonMapping(shortPress: .rightClick, longPress: .none, longPressMode: .directions, deviceScope: .keychronT1HE)
    let decoded = try JSONDecoder().decode(ButtonMapping.self, from: JSONEncoder().encode(mapping))
    #expect(decoded == mapping)
}

@Test func allDevicesNeedsNoLookup() {
    #expect(PointerDevices.serviceIDs(for: .all) == nil)
}
