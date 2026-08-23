import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device Apple Intelligence helper for answering questions about a listening process.
@available(macOS 26.0, *)
enum ProcessAgent {

    enum AvailabilityStatus: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: AvailabilityStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This Mac doesn’t support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in System Settings to use Ask.")
            case .modelNotReady:
                return .unavailable("Apple Intelligence is still downloading or preparing. Try again shortly.")
            @unknown default:
                return .unavailable("Apple Intelligence isn’t available right now.")
            }
        }
    }

    static func makeSession(for server: DevServer) -> LanguageModelSession {
        LanguageModelSession(instructions: instructions(for: server))
    }

    static func instructions(for server: DevServer) -> String {
        """
        You are a concise assistant inside Port Radar, a macOS menu-bar app that lists localhost listeners.
        The user is asking about one specific process. Use only the process context below.
        If something isn’t in the context, say you don’t know — don’t invent system state.
        Prefer short, practical answers for developers.

        Process context:
        \(server.sanitizedAgentContext.text)
        """
    }
}
#endif

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
