import Testing
import AppKit
import CoreGraphics
@testable import PrecisionButton

@Test func rootFeatureRequestEncoding() {
    let report = HIDPPPacket.rootFeatureRequest(deviceIndex: 2, featureID: 0x1B04)
    #expect(report.count == 20)
    #expect(Array(report.prefix(6)) == [0x11, 0x02, 0x00, 0x0D, 0x1B, 0x04])
}

@Test func functionEncoding() {
    let report = HIDPPPacket.request(deviceIndex: 1, featureIndex: 7, function: 3, parameters: [0x00, 0xED, 0x03])
    #expect(Array(report.prefix(7)) == [0x11, 0x01, 0x07, 0x3D, 0x00, 0xED, 0x03])
}

@Test func responseParsing() {
    let packet = HIDPPPacket(bytes: [0x11, 0x01, 0x07, 0x1D, 0x00, 0xED, 0x00])
    #expect(packet.deviceIndex == 1)
    #expect(packet.featureIndex == 7)
    #expect(packet.function == 1)
    #expect(packet.softwareID == 0x0D)
}

@Test func returnKeyHasVisibleLabel() {
    let shortcut = KeyboardShortcut(keyCode: 36, modifiers: 0, characters: "\r")
    #expect(shortcut.displayName == "↩")

    let commandReturn = KeyboardShortcut(keyCode: 36, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "\r")
    #expect(commandReturn.displayName == "⌘↩")
}

@Test func commandBackspaceHasVisibleLabel() {
    let shortcut = KeyboardShortcut(keyCode: 51, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "\u{8}")
    #expect(shortcut.displayName == "⌘⌫")
}

@Test func shortPressTriggersOnlyOnRelease() {
    var state = ButtonGestureState()
    let began = state.beginPress()
    let released = state.endPress()
    let duplicateRelease = state.endPress()
    #expect(began)
    #expect(released == .shortPress)
    #expect(duplicateRelease == .none)
}

@Test func longPressSuppressesShortPress() {
    var state = ButtonGestureState()
    let began = state.beginPress()
    let threshold = state.reachLongPressThreshold()
    let duplicateThreshold = state.reachLongPressThreshold()
    let released = state.endPress()
    #expect(began)
    #expect(threshold == .longPress)
    #expect(duplicateThreshold == .none)
    #expect(released == .none)
}

@Test func eachButtonHasItsNativeAction() {
    #expect(ButtonSource.left.nativeAction == .leftClick)
    #expect(ButtonSource.right.nativeAction == .rightClick)
    #expect(ButtonSource.back.nativeAction == .backClick)
    #expect(ButtonSource.forward.nativeAction == .forwardClick)
}

@Test func dominantTrackballDirection() {
    #expect(GestureDirection.dominant(deltaX: 3, deltaY: -30) == .up)
    #expect(GestureDirection.dominant(deltaX: 35, deltaY: 4) == .right)
    #expect(GestureDirection.dominant(deltaX: -28, deltaY: 2) == .left)
    #expect(GestureDirection.dominant(deltaX: 2, deltaY: 32) == .down)
    #expect(GestureDirection.dominant(deltaX: 4, deltaY: 4) == nil)
}

@Test func legacyMappingDefaultsToActionMode() throws {
    struct LegacyMapping: Codable {
        let shortPress: ButtonAction
        let longPress: ButtonAction
    }
    let data = try JSONEncoder().encode(LegacyMapping(shortPress: .leftClick, longPress: .missionControl))
    let mapping = try JSONDecoder().decode(ButtonMapping.self, from: data)
    #expect(mapping.longPressMode == .action)
    #expect(mapping.directionalActions.isEmpty)
}

@Test func capturesAllControlArrowShortcuts() throws {
    let expected: [(CGKeyCode, String)] = [
        (123, "⌃←"),
        (124, "⌃→"),
        (125, "⌃↓"),
        (126, "⌃↑")
    ]
    for (keyCode, label) in expected {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = .maskControl
        #expect(ShortcutCaptureMonitor.shortcut(from: event).displayName == label)
    }
}

@Test func postedArrowShortcutsIncludeSecondaryFnFlag() {
    for keyCode: CGKeyCode in 123...126 {
        let flags = ActionPerformer.keyboardFlags(for: keyCode, modifiers: .maskControl)
        #expect(flags.contains(.maskControl))
        #expect(flags.contains(.maskSecondaryFn))
        #expect(flags.rawValue == 0x840000)
    }
    let letterFlags = ActionPerformer.keyboardFlags(for: 0, modifiers: .maskControl)
    #expect(!letterFlags.contains(.maskSecondaryFn))
}

@Test func parsesUnifiedBatteryPercentage() throws {
    let battery = try #require(HIDPPBatteryParser.unified([87, 0x04, 0, 0], hasPercentage: true))
    #expect(battery.percentage == 87)
    #expect(battery.level == .good)
    #expect(battery.state == .discharging)
    #expect(battery.displayText == "87%（使用中）")
}

@Test func parsesBatteryLevelStatus() throws {
    let battery = try #require(HIDPPBatteryParser.levelStatus([55, 50, 0]))
    #expect(battery.percentage == 55)
    #expect(battery.level == .good)
    #expect(battery.state == .discharging)

    let charging = try #require(HIDPPBatteryParser.levelStatus([0, 0, 1]))
    #expect(charging.percentage == nil)
    #expect(charging.state == .charging)
}

@Test func parsesBatteryVoltageFallback() throws {
    let battery = try #require(HIDPPBatteryParser.voltage([0x0F, 0xA0, 0]))
    #expect(battery.voltageMillivolts == 4_000)
    #expect(battery.state == .discharging)
}
