import Foundation

/// Japanese literals double as the lookup keys, so `ja` needs no table and
/// only the English translations have to be maintained. The bundle's
/// development region is English, so any locale without its own table —
/// French, German, anything — lands on English rather than Japanese.
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string with `%@` placeholders, e.g. L("%@: 押下を検出", name).
///
/// Substitution is done by hand rather than through `String(format:)`: the
/// arguments here are a mix of strings, integers and enums, and `%@` with a
/// non-object argument is undefined behaviour.
func L(_ key: String, _ arguments: Any...) -> String {
    let template = Bundle.module.localizedString(forKey: key, value: key, table: nil)
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
