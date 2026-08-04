import AppKit
import Foundation
import Observation

enum TunnelStatus: Equatable {
    case downloading
    case starting
    case live
    case failed(String)
}

struct PortTunnel: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    let processName: String
    var publicURL: URL?
    var status: TunnelStatus
    let startedAt: Date

    var isLive: Bool {
        if case .live = status { return true }
        return false
    }
}

/// Cloudflare quick tunnels (`cloudflared tunnel --url`) keyed by local port.
@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()

    private(set) var tunnels: [PortTunnel] = []
    private var processes: [Int: Process] = [:]
    private var startTasks: [Int: Task<Void, Never>] = [:]

    var activeCount: Int {
        tunnels.filter {
            if case .failed = $0.status { return false }
            return true
        }.count
    }

    func tunnel(for port: Int) -> PortTunnel? {
        tunnels.first { $0.port == port }
    }

    func isShared(_ port: Int) -> Bool {
        guard let tunnel = tunnel(for: port) else { return false }
        switch tunnel.status {
        case .downloading, .starting, .live: return true
        case .failed: return false
        }
    }

    func startShare(port: Int, processName: String) {
        if let existing = tunnel(for: port) {
            switch existing.status {
            case .downloading, .starting, .live:
                return
            case .failed:
                break
            }
        }

        startTasks[port]?.cancel()
        stopShare(port: port)

        upsert(PortTunnel(
            port: port,
            processName: processName,
            publicURL: nil,
            status: .downloading,
            startedAt: Date()
        ))

        startTasks[port] = Task { [weak self] in
            guard let self else { return }
            do {
                let binary = try await CloudflaredBootstrap.resolveBinary()
                guard !Task.isCancelled else { return }
                self.launchCloudflared(binary: binary, port: port, processName: processName)
            } catch {
                guard !Task.isCancelled else { return }
                self.upsert(PortTunnel(
                    port: port,
                    processName: processName,
                    publicURL: nil,
                    status: .failed(error.localizedDescription),
                    startedAt: Date()
                ))
            }
            self.startTasks[port] = nil
        }
    }

    func stopShare(port: Int) {
        startTasks[port]?.cancel()
        startTasks[port] = nil
        if let process = processes.removeValue(forKey: port) {
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        tunnels.removeAll { $0.port == port }
    }

    func stopAll() {
        for port in tunnels.map(\.port) {
            stopShare(port: port)
        }
    }

    func prune(activePorts: Set<Int>) {
        for tunnel in tunnels where !activePorts.contains(tunnel.port) {
            stopShare(port: tunnel.port)
        }
    }

    func copyURL(for port: Int) {
        guard let url = tunnel(for: port)?.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Private

    private func launchCloudflared(binary: String, port: Int, processName: String) {
        upsert(PortTunnel(
            port: port,
            processName: processName,
            publicURL: nil,
            status: .starting,
            startedAt: Date()
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)"]
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        let onData: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                TunnelManager.shared.ingest(chunk, port: port)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = onData
        stdout.fileHandleForReading.readabilityHandler = onData

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(port: port, status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            processes[port] = process
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            upsert(PortTunnel(
                port: port,
                processName: processName,
                publicURL: nil,
                status: .failed(error.localizedDescription),
                startedAt: Date()
            ))
        }
    }

    private func upsert(_ tunnel: PortTunnel) {
        if let index = tunnels.firstIndex(where: { $0.port == tunnel.port }) {
            tunnels[index] = tunnel
        } else {
            tunnels.append(tunnel)
            tunnels.sort { $0.port < $1.port }
        }
    }

    private func handleTermination(port: Int, status: Int32) {
        if let process = processes[port] {
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        }
        processes[port] = nil
        guard var tunnel = tunnel(for: port) else { return }
        if tunnel.isLive { return }
        if case .failed = tunnel.status { return }
        tunnel.status = .failed(status == 0 ? "Tunnel closed" : "cloudflared exited (\(status))")
        upsert(tunnel)
    }

    func ingest(_ chunk: String, port: Int) {
        guard var tunnel = tunnel(for: port) else { return }
        if tunnel.publicURL != nil { return }
        if let url = Self.firstQuickTunnelURL(in: chunk) {
            tunnel.publicURL = url
            tunnel.status = .live
            upsert(tunnel)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
            options: [.caseInsensitive]
        )
    }()

    private static func firstQuickTunnelURL(in text: String) -> URL? {
        guard let regex = urlRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[swiftRange]))
    }
}
