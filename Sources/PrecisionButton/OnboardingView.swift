import AppKit
import CoreGraphics
import SwiftUI

/// First-run guide for the three permissions the app cannot work without.
/// Also reachable later from the General tab, because an app update can drop
/// the approvals and the failure is otherwise silent.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum Permission: CaseIterable, Identifiable {
        case accessibility, eventPosting, inputMonitoring

        var id: String { title }

        var title: String {
            switch self {
            case .accessibility: L("アクセシビリティ")
            case .eventPosting: L("操作送信")
            case .inputMonitoring: L("入力監視")
            }
        }

        var detail: String {
            switch self {
            case .accessibility: L("左右クリックの監視と、押しっぱなしジェスチャーに必要です。")
            case .eventPosting: L("割り当てたキー操作やクリックの送信に使います。システム設定に独立した項目はなく、アクセシビリティを許可すると一緒に有効になります。")
            case .inputMonitoring: L("トラックボール本体と通信し、ボタンを受け取るために必要です。")
            }
        }

        /// System Settings deep link for this permission.
        var settingsURL: URL? {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .eventPosting:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .inputMonitoring:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            }
        }
    }

    private func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: model.accessibilityGranted
        case .eventPosting: model.eventPostingGranted
        case .inputMonitoring: model.inputMonitoringGranted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Elgotune を使う準備"))
                    .font(.title.bold())
                Text(L("トラックボールを制御するために、3つの許可が必要です。下のボタンからシステム設定を開き、リストの Elgotune をオンにしてください。"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Permission.allCases) { permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isGranted(permission) ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isGranted(permission) ? .green : .secondary)
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(.headline)
                        Text(permission.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if isGranted(permission) {
                        Text(L("許可済み"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if permission == .eventPosting {
                        // No switch exists for this one; asking is all we can do.
                        Button(L("許可を求める")) { _ = CGRequestPostEventAccess() }
                    } else if let url = permission.settingsURL {
                        Button(L("開く")) { NSWorkspace.shared.open(url) }
                    }
                }
            }

            Divider()

            Label(
                L("アプリを更新すると許可が外れることがあります。そのときは一覧から Elgotune を削除して、追加し直してください。"),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(L("まとめて許可を求める")) { model.requestPermissions() }
                Spacer()
                Button(model.allPermissionsGranted ? L("はじめる") : L("あとで")) {
                    model.markOnboardingSeen()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(refresh) { _ in model.refreshPermissions(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
