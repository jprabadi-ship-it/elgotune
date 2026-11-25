import AppKit
import Foundation
import Security

/// Looks for a newer release on GitHub at launch and, when the user agrees,
/// downloads and verifies it, then quits and lets a small helper swap the
/// bundle and relaunch it.
///
/// The only request it makes before asking is one GET of the latest
/// release's metadata; nothing about the user or the Mac is sent.
@MainActor
final class Updater {
    static let repository = "jprabadi-ship-it/elgotune"
    /// The new bundle must carry this identifier, be signed by this team's
    /// Developer ID and be notarized — the same checks Gatekeeper makes,
    /// so a tampered download is refused before anything is replaced.
    static let requirement = #"identifier "com.gigowat.elgotune" and anchor apple generic and certificate leaf[subject.OU] = "3HCG7Y94FX" and notarized"#

    private let log: (String) -> Void
    private var running = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    struct Release: Equatable {
        let version: String
        let downloadURL: URL
        let pageURL: URL?
    }

    enum UpdateError: LocalizedError {
        case noDiskImage
        case appMissingInImage
        case verificationFailed(String)
        case versionMismatch(String)
        case notWritable(String)
        case command(String, String)

        var errorDescription: String? {
            switch self {
            case .noDiskImage: L("配布ファイル（.dmg）が見つかりません")
            case .appMissingInImage: L("ダウンロードしたファイルにアプリが入っていません")
            case .verificationFailed(let detail): L("署名の確認に失敗しました: %@", detail)
            case .versionMismatch(let found): L("ダウンロードしたアプリの版が一致しません（%@）", found)
            case .notWritable(let path): L("%@ に書き込めません", path)
            case .command(let name, let output): L("%@ が失敗しました: %@", name, output)
            }
        }
    }

    // MARK: - Launch check

    func checkAtLaunch() {
        guard !running, Self.isInstalledBundle else { return }
        running = true
        Task {
            defer { running = false }
            do {
                guard let release = try await Self.fetchLatestRelease(),
                      Self.isNewer(release.version, than: Self.currentVersion) else { return }
                guard UserDefaults.standard.string(forKey: "skippedUpdateVersion") != release.version else {
                    log(L("新しいバージョン %@ はスキップ済みです", release.version))
                    return
                }
                log(L("新しいバージョン %@ があります", release.version))
                guard ask(about: release) else { return }
                try await install(release)
            } catch {
                log(L("更新を確認できませんでした: %@", error.localizedDescription))
            }
        }
    }

    /// Updating a copy that `swift run` or a build script left somewhere
    /// would replace the wrong thing.
    static var isInstalledBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && !Bundle.main.bundleURL.path.hasPrefix("/tmp/")
            && !Bundle.main.bundleURL.path.hasPrefix("/private/tmp/")
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares dotted numbers; "v" prefixes and missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              (object["draft"] as? Bool) != true,
              (object["prerelease"] as? Bool) != true,
              let assets = object["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let link = dmg["browser_download_url"] as? String,
              let url = URL(string: link), url.scheme == "https" else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return Release(version: version, downloadURL: url, pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)))
    }

    private static func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Elgotune", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseRelease(data)
    }

    // MARK: - Asking

    private func ask(about release: Release) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Elgotune %@ が公開されています", release.version)
        alert.informativeText = L("いまお使いの版は %@ です。ダウンロードしてインストールしますか？\n準備ができたら Elgotune を一度終了し、新しい版に置き換えて起動し直します。", Self.currentVersion)
        alert.addButton(withTitle: L("ダウンロードしてインストール"))
        alert.addButton(withTitle: L("あとで"))
        alert.addButton(withTitle: L("この版はスキップ"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
            log(L("バージョン %@ をスキップしました", release.version))
            return false
        default:
            return false
        }
    }

    private func report(_ error: Error) {
        log(L("更新できませんでした: %@", error.localizedDescription))
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("更新できませんでした")
        alert.informativeText = L("%@\nいまの版をそのまま使えます。", error.localizedDescription)
        alert.runModal()
    }

    // MARK: - Download, verify, hand over

    private func install(_ release: Release) async throws {
        let target = Bundle.main.bundleURL
        do {
            try Self.checkWritable(target)
            log(L("バージョン %@ をダウンロード中…", release.version))
            let work = FileManager.default.temporaryDirectory.appending(path: "elgotune-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let staged = try await Self.prepare(release, in: work)
            log(L("バージョン %@ の署名を確認しました。置き換えのため終了します", release.version))
            try Self.launchHelper(staged: staged, target: target, work: work)
        } catch {
            report(error)
            return
        }
        // willTerminate hands the trackball back to macOS first.
        NSApplication.shared.terminate(nil)
    }

    private static func checkWritable(_ target: URL) throws {
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent),
              FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateError.notWritable(parent)
        }
    }

    /// Everything up to the swap: download, mount, copy out, unmount, verify.
    private static func prepare(_ release: Release, in work: URL) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noDiskImage }
        let dmg = work.appending(path: "Elgotune.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        let mount = work.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appending(path: "Elgotune.app")
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.appMissingInImage }
            try await run("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path])

        try verify(staged)
        let found = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard found == release.version else { throw UpdateError.versionMismatch(found) }
        return staged
    }

    private static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.verificationFailed("SecStaticCode")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? String(status)
            throw UpdateError.verificationFailed(detail)
        }
    }

    /// The helper outlives this process: it waits for it to exit, swaps the
    /// bundle in place and opens the new one. A failed swap puts the old
    /// bundle back and reopens that instead.
    private static func launchHelper(staged: URL, target: URL, work: URL) throws {
        let script = #"""
        pid="$1"; new="$2"; target="$3"; work="$4"
        for i in {1..300}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && exit 1
        old="$work/previous.app"
        if mv "$target" "$old"; then
          if mv "$new" "$target"; then
            rm -rf "$old"
          else
            mv "$old" "$target"
          fi
        fi
        open "$target"
        rm -rf "$work"
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script, "elgotune-update", String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw UpdateError.command(URL(fileURLWithPath: tool).lastPathComponent, output)
            }
            return output
        }.value
    }
}
