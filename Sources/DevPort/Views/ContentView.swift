import SwiftUI

/// A pending kill awaiting user confirmation.
struct KillRequest: Identifiable {
    let server: DevServer
    let force: Bool
    var id: String { server.id }
}

struct ContentView: View {
    private var state = AppState.shared
    @State private var killRequest: KillRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .alert(
            killRequest.map { "\($0.force ? "Force kill" : "Stop") \($0.server.processName) on port \(String($0.server.port))?" } ?? "",
            isPresented: Binding(
                get: { killRequest != nil },
                set: { if !$0 { killRequest = nil } }
            ),
            presenting: killRequest
        ) { request in
            Button(request.force ? "Force Kill" : "Stop", role: .destructive) {
                let pid = request.server.pid
                if request.force {
                    ProcessActions.forceKill(pid: pid)
                } else {
                    Task { await ProcessActions.stop(pid: pid) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(alertMessage(for: request))
        }
    }

    private func alertMessage(for request: KillRequest) -> String {
        var parts: [String] = []
        if request.server.isSystemProcess {
            parts.append("This is a normal macOS system process. Killing it is rarely needed — the system may relaunch it automatically.")
        }
        if !request.force {
            parts.append("Sends SIGTERM, escalating to SIGKILL if the process doesn't exit within a few seconds.")
        }
        return parts.joined(separator: "\n\n")
    }

    private var header: some View {
        HStack {
            Text("DevPort")
                .font(.headline)
            Spacer()
            Text("\(state.servers.count) listening")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("No servers detected")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var serverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.servers) { server in
                    ServerRow(server: server) { force in
                        killRequest = KillRequest(server: server, force: force)
                    }
                    if server.id != state.servers.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        // ScrollView collapses to zero height inside a MenuBarExtra window
        // unless given an explicit height, so estimate from the row count.
        .frame(height: min(420, CGFloat(state.servers.count) * 47))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit DevPort") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ServerRow: View {
    let server: DevServer
    let onKill: (_ force: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text(server.processName)
                    .font(.system(.body, weight: .medium))
                if server.isSystemProcess {
                    Text("System")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("Normal macOS system process — safe to leave running; killing it is rarely needed")
                }
                Spacer()
                Text("localhost:\(String(server.port))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    onKill(false)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop gracefully — asks the process to quit (SIGTERM), force kills after 4 s if it doesn't")
                Button {
                    onKill(true)
                } label: {
                    Image(systemName: "bolt.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Force kill immediately (SIGKILL) — no chance to clean up")
            }
            HStack(spacing: 6) {
                Text("pid \(String(server.pid))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let command = server.command {
                    Text(command)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
