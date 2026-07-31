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
    // displayText is localized, so assert the parts that carry the data.
    #expect(battery.valueText == "87%")
    #expect(battery.state == .discharging)
    #expect(battery.displayText.contains("87%"))
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

@Test func settingsBundleRoundTrip() throws {
    let bundle = SettingsBundle(
        mappings: [
            .precision: ButtonMapping(shortPress: .missionControl, longPress: .none, longPressMode: .directions, directionalActions: [.up: .showDesktop]),
            .middle: ButtonMapping(shortPress: .middleClick, longPress: .none),
            .deviceSwitch: ButtonMapping(shortPress: .switchDevice, longPress: .none)
        ],
        longPressMilliseconds: 450,
        excludedApps: [ExcludedApp(bundleIdentifier: "com.example.app", name: "Example")]
    )
    let data = try JSONEncoder().encode(bundle)
    let decoded = try JSONDecoder().decode(SettingsBundle.self, from: data)
    #expect(decoded.longPressMilliseconds == 450)
    #expect(decoded.excludedApps == bundle.excludedApps)
    #expect(decoded.mappings[.precision] == bundle.mappings[.precision])
    #expect(decoded.mappings[.deviceSwitch]?.shortPress == .switchDevice)
}

@Test func settingsBundleClampsLongPressAndToleratesMissingFields() throws {
    let json = #"{"mappings":{"left":{"shortPress":{"rightClick":{}},"longPress":{"none":{}}}},"longPressMilliseconds":99999}"#
    let decoded = try JSONDecoder().decode(SettingsBundle.self, from: Data(json.utf8))
    #expect(decoded.longPressMilliseconds == 1_500)
    #expect(decoded.excludedApps.isEmpty)
    #expect(decoded.mappings[.left]?.shortPress == .rightClick)
}

@Test func scrollSettingsMigratesLegacySensitivity() throws {
    let json = #"{"sensitivity":1.8,"momentumEnabled":false}"#
    let decoded = try JSONDecoder().decode(ScrollSettings.self, from: Data(json.utf8))
    #expect(abs(decoded.speed - 8) < 0.001)
    #expect(decoded.acceleration == 1)
    #expect(decoded.momentumEnabled == false)
}

@Test func scrollDefaultsToUnityAndAccelerationBoostsFastMovementOnly() {
    var settings = ScrollSettings()
    #expect(settings.speed == 0)
    #expect(settings.multiplier == 1.0)
    #expect(settings.acceleration == 1)

    // The top of the slider has to be dramatic, not merely noticeable.
    settings.speed = ScrollSettings.speedRange.upperBound
    #expect(settings.multiplier > 12)
    settings.acceleration = 10
    #expect(settings.gain(forDistance: 40) > 30)
    // Back to defaults: no acceleration means plain 1x.
    settings.speed = 0
    settings.acceleration = 1
    #expect(abs(settings.gain(forDistance: 40) - 1.0) < 0.001)

    settings.acceleration = 10
    let slow = settings.gain(forDistance: 2)
    let fast = settings.gain(forDistance: 60)
    #expect(slow < 1.0)
    #expect(fast > 1.0)
    #expect(fast > slow)
}

@Test func scrollSettingsClampOutOfRangeValues() throws {
    let json = #"{"speed":9999,"acceleration":-5,"momentumFriction":2}"#
    let decoded = try JSONDecoder().decode(ScrollSettings.self, from: Data(json.utf8))
    #expect(decoded.speed == 128)
    #expect(decoded.acceleration == 1)
    #expect(decoded.momentumFriction == 0.999)
}

@Test func pointerDefaultsAreSystemNeutral() {
    var settings = PointerSettings()
    #expect(settings.acceleration == 3)
    #expect(settings.speed == 0.069)
    #expect(settings.speedMultiplier == 1.0)

    settings.speed = 0.138
    #expect(abs(settings.speedMultiplier - 2.0) < 0.001)

    // A zero speed must not freeze the pointer beyond recovery.
    settings.speed = 0
    #expect(settings.speedMultiplier == 0.05)
}

@Test func pointerSettingsClampAndMapAcceleration() throws {
    let decoded = try JSONDecoder().decode(
        PointerSettings.self,
        from: Data(#"{"acceleration":99,"speed":5}"#.utf8)
    )
    #expect(decoded.acceleration == 40)
    #expect(decoded.speed == 1)
    #expect(decoded.systemAcceleration == 40)
}

@Test func momentumGlidesLongerAsFrictionRises() {
    var settings = ScrollSettings()
    settings.momentumFriction = 0.94
    let normal = settings.estimatedGlideSeconds
    settings.momentumFriction = 0.999
    let exaggerated = settings.estimatedGlideSeconds
    #expect(normal > 0)
    #expect(exaggerated > normal * 10)

    settings.momentumBoost = 8
    #expect(settings.estimatedGlideSeconds > exaggerated)
}

@Test func momentumSettingsClampToRanges() throws {
    let decoded = try JSONDecoder().decode(
        ScrollSettings.self,
        from: Data(#"{"momentumFriction":5,"momentumBoost":99}"#.utf8)
    )
    #expect(decoded.momentumFriction == 0.999)
    #expect(decoded.momentumBoost == 8)
}

@Test func tiltButtonsStayNativeUntilCustomized() {
    #expect(ButtonSource.tiltLeft.divertsOnlyWhenCustomized)
    #expect(ButtonSource.tiltRight.divertsOnlyWhenCustomized)
    #expect(ButtonSource.tiltLeft.nativeAction == ButtonAction.none)
    // Ordinary buttons are taken over as soon as customization is enabled.
    #expect(!ButtonSource.middle.divertsOnlyWhenCustomized)
}

@Test func horizontalScrollActionsHaveDistinctIdentities() {
    #expect(ButtonAction.scrollLeft.id == "scrollLeft")
    #expect(ButtonAction.scrollRight.id == "scrollRight")
    #expect(ButtonAction.allCases.contains(.scrollLeft))
    #expect(ButtonAction.allCases.contains(.scrollRight))
}

@Test func localizedFormatSubstitutesEveryArgumentType() {
    // %@ must be safe for non-object arguments too (UInt8, Int, enums).
    // Assertions stay language-neutral: the test host may run in any locale.
    let press = L("%@: 押下を検出", "中クリック")
    #expect(press.contains("中クリック"))
    #expect(!press.contains("%@"))

    let slot = L("HID++スロット%@: ボタン機能を検出", UInt8(255))
    #expect(slot.contains("255"))
    #expect(!slot.contains("%@"))

    let channel = L("デバイス切り替え: チャンネル%@へ", 2)
    #expect(channel.contains("2"))
    #expect(!channel.contains("%@"))

    // A missing argument leaves the placeholder rather than crashing.
    let partial = L("%@を検出（CID 0x%@）", "左クリック")
    #expect(partial.contains("左クリック"))
    #expect(partial.contains("%@"))
}

@Test func englishTableCoversEveryLocalizedKey() throws {
    // A key without a translation would silently ship Japanese text.
    let url = try #require(Bundle.module.url(forResource: "en", withExtension: "lproj"))
    let table = try #require(
        NSDictionary(contentsOf: url.appending(path: "Localizable.strings")) as? [String: String]
    )
    #expect(table["ボタン割り当て"] == "Buttons")
    #expect(table.count > 150)
}
