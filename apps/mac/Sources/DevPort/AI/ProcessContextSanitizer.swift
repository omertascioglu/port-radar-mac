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
        var sanitizedArguments: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if isStandaloneSensitiveCommandLineOption(argument),
               arguments.indices.contains(index + 1) {
                let nextArgument = arguments[index + 1]
                if isAuthorizationCommandLineOption(argument),
                   nextArgument.caseInsensitiveCompare("Bearer") == .orderedSame {
                    if arguments.indices.contains(index + 2) {
                        let credential = arguments[index + 2]
                        if !credential.isEmpty,
                           !looksLikeCommandLineOption(credential) {
                            sanitizedArguments.append(
                                "\(argument)=\(redactionMarker)"
                            )
                            index += 3
                            continue
                        }
                    }

                    sanitizedArguments.append(argument)
                    index += 1
                    continue
                }
                if !nextArgument.isEmpty,
                   !looksLikeCommandLineOption(nextArgument) {
                    sanitizedArguments.append(
                        "\(argument)=\(redactionMarker)"
                    )
                    index += 2
                    continue
                }
            }
            sanitizedArguments.append(sanitizeCommandArgument(argument))
            index += 1
        }
        return sanitizedArguments.joined(separator: " ")
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
        return sanitize(value).text
    }

    private static func isStandaloneSensitiveCommandLineOption(
        _ argument: String
    ) -> Bool {
        let pattern =
            #"(?i)^--(?=[A-Za-z0-9_-]*\#(sensitiveName))[A-Za-z0-9][A-Za-z0-9_-]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else { return true }
        let range = NSRange(argument.startIndex..., in: argument)
        return expression.firstMatch(in: argument, range: range) != nil
    }

    private static func isAuthorizationCommandLineOption(
        _ argument: String
    ) -> Bool {
        argument.range(
            of: "authorization",
            options: .caseInsensitive
        ) != nil
    }

    private static func looksLikeCommandLineOption(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), argument != "-" else { return false }
        if argument == "--" { return true }
        let name = argument.drop(while: { $0 == "-" })
        return name.first?.isLetter == true
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

extension DevServer {
    /// Provider-neutral process snapshot before sensitive values are removed.
    var rawAgentContext: String {
        agentContext(command: command)
    }

    /// Process snapshot safe to share with either local AI provider.
    var sanitizedAgentContext: SanitizedProcessContext {
        guard let commandArguments, !commandArguments.isEmpty else {
            return ProcessContextSanitizer.sanitize(rawAgentContext)
        }
        let safeCommand = ProcessContextSanitizer.sanitizeCommand(
            arguments: commandArguments
        )
        return SanitizedProcessContext(
            text: agentContext(
                command: safeCommand,
                preservingSanitizedCommand: true
            )
        )
    }

    private func agentContext(
        command commandSnapshot: String?,
        preservingSanitizedCommand: Bool = false
    ) -> String {
        var lines: [String] = [
            "port: \(port)",
            "url: http://localhost:\(port)",
            "pid: \(pid)",
            "processName: \(processName)",
            "isSystemProcess: \(isSystemProcess)",
            "isOrphaned: \(isOrphaned)",
        ]
        if let parentPID {
            lines.append("parentPID: \(parentPID)")
        }
        if let executablePath {
            lines.append("executablePath: \(executablePath)")
        }
        if let workingDirectory {
            lines.append("workingDirectory: \(workingDirectory)")
        }
        var commandLineIndex: Int?
        if let commandSnapshot {
            commandLineIndex = lines.count
            lines.append("command: \(commandSnapshot)")
        }
        if let startTime {
            lines.append("startTime: \(startTime.formatted(date: .abbreviated, time: .standard))")
            if let uptime = formattedUptime() {
                lines.append("uptime: \(uptime)")
            }
        }
        if let project {
            lines.append("projectName: \(project.name)")
            lines.append("projectRoot: \(project.rootPath)")
            lines.append("framework: \(project.framework.rawValue)")
        }
        if preservingSanitizedCommand {
            for index in lines.indices where index != commandLineIndex {
                lines[index] = ProcessContextSanitizer.sanitize(lines[index]).text
            }
        }
        return lines.joined(separator: "\n")
    }
}
