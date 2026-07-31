import SwiftUI

@main
struct PrecisionButtonApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ErgoTune", id: "settings") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 800)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            MenuBarBatteryLabel(battery: model.primaryBattery, enabled: model.isEnabled)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("設定画面を開く")) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        if let battery = model.primaryBattery {
            Label(L("バッテリー: %@", battery.displayText), systemImage: battery.systemImage)
        } else {
            Label(L("バッテリーを取得中…"), systemImage: "battery.0percent")
        }

        Text(model.statusText)
        Divider()

        Button(model.isEnabled ? L("カスタマイズを停止") : L("カスタマイズを開始")) {
            model.isEnabled.toggle()
        }
        Divider()
        Button(L("終了")) { NSApplication.shared.terminate(nil) }
    }
}

private struct MenuBarBatteryLabel: View {
    let battery: LogitechBattery?
    let enabled: Bool

    private var value: String {
        guard enabled else { return "×" }
        guard let battery else { return "–" }
        if let percentage = battery.percentage { return String(percentage) }
        switch battery.level {
        case .critical: return "!"
        case .low: return "L"
        case .good: return "G"
        case .full: return "100"
        case .unknown: return "?"
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: enabled ? "circle.circle.fill" : "circle.slash")
                .font(.system(size: 17, weight: .medium))
            Text(value)
                .font(.system(size: value.count >= 3 ? 6 : 8, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.background)
        }
        .frame(width: 22, height: 18)
        .accessibilityLabel(L("ErgoTune、バッテリー %@", battery?.displayText ?? L("取得中")))
    }
}
