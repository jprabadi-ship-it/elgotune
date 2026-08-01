import Foundation
import ServiceManagement

/// Launch-at-login through SMAppService. The app must live in /Applications
/// and be signed for macOS to accept the registration.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message explaining why it failed.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                return L("システム設定 > 一般 > ログイン項目 で Spintune を許可してください")
            }
            return L("ログイン時起動を変更できません: %@", error.localizedDescription)
        }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: L("有効")
        case .requiresApproval: L("システム設定での承認待ち")
        case .notRegistered: L("無効")
        case .notFound: L("登録できません（/Applications に配置してください）")
        @unknown default: L("不明")
        }
    }
}
