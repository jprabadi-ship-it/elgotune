import Foundation

/// SwiftPM's generated `Bundle.module` aborts the process when the resource
/// bundle is not where it expects, and where it looks depends on the
/// toolchain that compiled the app. The one behind releases 0.1.5 to 1.0.1
/// checked next to the .app and the build directory on the developer's
/// disk, never Contents/Resources, so those builds only ran on the machine
/// that made them. The lookup lives here instead, and a miss degrades to
/// the untranslated keys rather than a crash at launch.
private let localizationBundle: Bundle = {
    let name = "PrecisionButton_PrecisionButton.bundle"
    let roots: [URL?] = [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        // `swift run` and the test runner keep it beside the executable.
        Bundle.main.executableURL?.deletingLastPathComponent()
    ]
    for root in roots {
        guard let url = root?.appending(path: name),
              FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url) else { continue }
        return bundle
    }
    return .main
}()

/// Japanese literals double as the lookup keys, so `ja` needs no table and
/// only the English translations have to be maintained. The bundle's
/// development region is English, so any locale without its own table —
/// French, German, anything — lands on English rather than Japanese.
func L(_ key: String) -> String {
    localizationBundle.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string with `%@` placeholders, e.g. L("%@: 押下を検出", name).
///
/// Substitution is done by hand rather than through `String(format:)`: the
/// arguments here are a mix of strings, integers and enums, and `%@` with a
/// non-object argument is undefined behaviour.
func L(_ key: String, _ arguments: Any...) -> String {
    let template = localizationBundle.localizedString(forKey: key, value: key, table: nil)
    var result = ""
    var remaining = Substring(template)
    var index = 0
    while let placeholder = remaining.range(of: "%@") {
        result += remaining[remaining.startIndex..<placeholder.lowerBound]
        if index < arguments.count {
            result += describe(arguments[index])
            index += 1
        } else {
            result += "%@"
        }
        remaining = remaining[placeholder.upperBound...]
    }
    result += remaining
    return result
}

private func describe(_ value: Any) -> String {
    if let text = value as? String { return text }
    if let convertible = value as? CustomStringConvertible { return convertible.description }
    return String(describing: value)
}
