import Foundation

enum ProcessContextSanitizer {
    private static let redactionMarker = "[REDACTED]"
    private static let sensitiveName =
        "(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|" +
        "private[_-]?key|client[_-]?secret|authorization|cookie)"

    static func sanitize(_ raw: String) -> SanitizedProcessContext {
        let environmentAssignment =
            #"(?i)(^|\s)((?=[A-Za-z0-9_-]*\#(sensitiveName))[A-Za-z_][A-Za-z0-9_-]*)=([^\s]+)"#
        let commandLineOption =
            #"(?i)(--(?=[A-Za-z0-9_-]*\#(sensitiveName))[A-Za-z0-9][A-Za-z0-9_-]*)(?:=|[^\S\r\n]+)([^\s]+)"#
        let bearerCredential =
            #"(?i)(\bBearer)[^\S\r\n]+[A-Za-z0-9._~+/=-]+"#
        let urlUserInfo =
            #"(?i)(\b[A-Za-z][A-Za-z0-9+.-]*://)[^/\s@?#]+@"#
        let sensitiveQueryParameter =
            #"(?i)([?&](?=[A-Za-z0-9_.-]*\#(sensitiveName))[A-Za-z0-9_.-]+=)[^&#\s]+"#
        let highConfidenceCredential =
            #"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|xox[A-Za-z0-9]+-[A-Za-z0-9-]{12,}|sk-[A-Za-z0-9_-]{12,})\b"#
        var value = replacing(
            bearerCredential,
            in: raw,
            with: "$1 \(redactionMarker)"
        )
        value = replacing(
            environmentAssignment,
            in: value,
            with: "$1$2=\(redactionMarker)"
        )
        value = replacing(
            commandLineOption,
            in: value,
            with: "$1=\(redactionMarker)"
        )
        value = replacing(
            urlUserInfo,
            in: value,
            with: "$1\(redactionMarker)@"
        )
        value = replacing(
            sensitiveQueryParameter,
            in: value,
            with: "$1\(redactionMarker)"
        )
        value = replacing(
            highConfidenceCredential,
            in: value,
            with: redactionMarker
        )
        return SanitizedProcessContext(text: value)
    }

    static func sanitizeCommand(arguments: [String]) -> String {
        let sanitizedArguments = arguments.map(sanitizeCommandArgument)
        return sanitize(sanitizedArguments.joined(separator: " ")).text
    }

    private static func sanitizeCommandArgument(_ argument: String) -> String {
        let environmentAssignment =
            #"(?i)^((?=[A-Za-z0-9_-]*\#(sensitiveName))[A-Za-z_][A-Za-z0-9_-]*=)[\s\S]*$"#
        let commandLineOption =
            #"(?i)^(--(?=[A-Za-z0-9_-]*\#(sensitiveName))[A-Za-z0-9][A-Za-z0-9_-]*)(?:=|[^\S\r\n]+)[\s\S]*$"#
        var value = replacing(
            environmentAssignment,
            in: argument,
            with: "$1\(redactionMarker)"
        )
        value = replacing(
            commandLineOption,
            in: value,
            with: "$1=\(redactionMarker)"
        )
        return value
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return redactionMarker
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}
