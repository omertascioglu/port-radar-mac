import SwiftUI

/// Servers grouped by detected project (or System / Other buckets).
struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let framework: Framework?
    let rootPath: String?
    let servers: [DevServer]
}

/// In-window kill confirmation — system `.alert` dismisses MenuBarExtra panels.
struct KillPrompt: Identifiable {
    let server: DevServer
    let force: Bool
    var id: String { "\(server.id)-\(force)" }
}

enum KillPhase {
    case confirm
    case working
    case result(KillOutcome)
}

struct ContentView: View {
    private var state = AppState.shared
    private var preferences = Preferences.shared
    @State private var killPrompt: KillPrompt?
    @State private var killPhase: KillPhase = .confirm
    @State private var showQuitConfirm = false
    @State private var showSettings = false
    @State private var agentServer: DevServer?
    @State private var showTunnels = false
    @State private var tunnelsFocusPort: Int?

    private var tunnels = TunnelManager.shared

    private var visibleServers: [DevServer] {
        state.servers.filter { preferences.matchesFilters($0) }
    }

    private var groups: [ProjectGroup] {
        var projects: [String: [DevServer]] = [:]
        var system: [DevServer] = []
        var other: [DevServer] = []

        for server in visibleServers {
            if let project = server.project {
                projects[project.rootPath, default: []].append(server)
            } else if server.isSystemProcess {
                system.append(server)
            } else {
                other.append(server)
            }
        }

        var result: [ProjectGroup] = projects
            .map { root, servers in
                let project = servers.first!.project!
                return ProjectGroup(
                    id: root,
                    name: project.name,
                    framework: project.framework,
                    rootPath: root,
                    servers: servers.sorted { $0.port < $1.port }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !other.isEmpty {
            result.append(ProjectGroup(
                id: "other", name: "Other", framework: nil, rootPath: nil,
                servers: other.sorted { $0.port < $1.port }
            ))
        }
        if !system.isEmpty {
            result.append(ProjectGroup(
                id: "system", name: "System", framework: nil, rootPath: nil,
                servers: system.sorted { $0.port < $1.port }
            ))
        }
        return result
    }

    private var isBusy: Bool {
        if case .working = killPhase { return true }
        return false
    }

    private var isModalPresented: Bool {
        killPrompt != nil || showQuitConfirm || showSettings || agentServer != nil || showTunnels
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if visibleServers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
                Divider()
                footer
            }
            .disabled(isModalPresented)
            .opacity(isModalPresented ? 0.25 : 1)

            if isModalPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
            }

            if let prompt = killPrompt {
                KillModal(
                    prompt: prompt,
                    phase: killPhase,
                    onConfirm: { await runKill(prompt) },
                    onDismiss: {
                        guard !isBusy else { return }
                        killPrompt = nil
                        killPhase = .confirm
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showQuitConfirm {
                QuitModal(
                    onConfirm: { NSApplication.shared.terminate(nil) },
                    onDismiss: { showQuitConfirm = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showSettings {
                SettingsModal(onDismiss: { showSettings = false })
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if let agentServer {
                AgentChatModal(
                    server: agentServer,
                    onDismiss: { self.agentServer = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showTunnels {
                TunnelsModal(
                    focusPort: tunnelsFocusPort,
                    onDismiss: {
                        showTunnels = false
                        tunnelsFocusPort = nil
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: 380)
        .animation(.easeOut(duration: 0.15), value: killPrompt?.id)
        .animation(.easeOut(duration: 0.15), value: showQuitConfirm)
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .animation(.easeOut(duration: 0.15), value: agentServer?.id)
        .animation(.easeOut(duration: 0.15), value: showTunnels)
    }

    private func runKill(_ prompt: KillPrompt) async {
        killPhase = .working
        let outcome: KillOutcome
        if prompt.force {
            outcome = await ProcessActions.forceKill(pid: prompt.server.pid)
        } else {
            outcome = await ProcessActions.stop(pid: prompt.server.pid)
        }
        killPhase = .result(outcome)
        // Brief pause so the user can read the result before the modal closes.
        try? await Task.sleep(for: .milliseconds(1100))
        killPrompt = nil
        killPhase = .confirm
    }

    private var header: some View {
        HStack {
            Text("Port Radar")
                .font(.headline)
            Spacer()
            Text("\(visibleServers.count) listening")
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
                ForEach(groups) { group in
                    GroupHeader(group: group)
                    ForEach(group.servers) { server in
                        ServerRow(
                            server: server,
                            onAskAgent: {
                                guard !isModalPresented else { return }
                                agentServer = server
                            },
                            onShareTunnel: {
                                guard !isModalPresented else { return }
                                tunnels.startShare(port: server.port, processName: server.processName)
                                tunnelsFocusPort = server.port
                                showTunnels = true
                            },
                            onManageTunnels: {
                                guard !isModalPresented else { return }
                                tunnelsFocusPort = server.port
                                showTunnels = true
                            },
                            onKill: { force in
                                guard !isModalPresented else { return }
                                killPhase = .confirm
                                killPrompt = KillPrompt(server: server, force: force)
                            }
                        )
                    }
                }
            }
        }
        // ScrollView collapses to zero height inside a MenuBarExtra window
        // unless given an explicit height, so estimate from the content.
        .frame(height: min(
            420,
            CGFloat(visibleServers.count) * 47 + CGFloat(groups.count) * 27
        ))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                guard !isModalPresented else { return }
                tunnelsFocusPort = nil
                showTunnels = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                    Text("Tunnels")
                    Spacer()
                    if tunnels.activeCount > 0 {
                        Text("\(tunnels.activeCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            Button {
                guard !isModalPresented else { return }
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            Button {
                guard !isModalPresented else { return }
                showQuitConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                    Text("Quit Port Radar")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}

struct QuitModal: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quit Port Radar?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("The menu bar app will close. Listening servers keep running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ModalButtonStyle(kind: .cancel))
                .keyboardShortcut(.cancelAction)

                Button(action: onConfirm) {
                    Text("Quit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ModalButtonStyle(kind: .destructive))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .white.opacity(0.18), radius: 28, y: 0)
        .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
    }
}

struct KillModal: View {
    let prompt: KillPrompt
    let phase: KillPhase
    let onConfirm: () async -> Void
    let onDismiss: () -> Void

    private var title: String {
        let action = prompt.force ? "Force kill" : "Stop"
        return "\(action) \(prompt.server.processName)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("localhost:\(String(prompt.server.port)) · pid \(String(prompt.server.pid))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            switch phase {
            case .confirm:
                confirmBody
            case .working:
                workingBody
            case .result(let outcome):
                resultBody(outcome)
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .white.opacity(0.18), radius: 28, y: 0)
        .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
    }

    @ViewBuilder
    private var confirmBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.server.isSystemProcess {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("System process — macOS may relaunch it automatically.")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                prompt.force
                    ? "Kills immediately with SIGKILL. The process has no chance to clean up."
                    : "Asks the process to quit (SIGTERM). Force kills after a few seconds if it doesn't exit."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Button(action: onDismiss) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ModalButtonStyle(kind: .cancel))
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await onConfirm() }
            } label: {
                Text(prompt.force ? "Force Kill" : "Stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ModalButtonStyle(kind: .destructive))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private var workingBody: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(prompt.force ? "Force killing…" : "Stopping…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func resultBody(_ outcome: KillOutcome) -> some View {
        HStack(spacing: 8) {
            switch outcome {
            case .stopped:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("Stopped")
                    .font(.callout.weight(.medium))
            case .failed(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct ModalButtonStyle: ButtonStyle {
    enum Kind { case cancel, destructive }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                fillColor.opacity(configuration.isPressed ? 0.55 : 0.72),
                                fillColor.opacity(configuration.isPressed ? 0.42 : 0.58),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: fillColor.opacity(0.35), radius: 8, y: 2)
    }

    private var fillColor: Color {
        switch kind {
        case .cancel: Color(red: 0.22, green: 0.72, blue: 0.38)
        case .destructive: Color(red: 0.92, green: 0.28, blue: 0.28)
        }
    }
}

struct GroupHeader: View {
    let group: ProjectGroup

    var body: some View {
        HStack(spacing: 5) {
            if let framework = group.framework {
                FrameworkIcon(framework: framework, size: 14)
            }
            Text(group.name)
                .font(.system(.subheadline, weight: .semibold))
            if let rootPath = group.rootPath {
                Text(rootPath.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path,
                    with: "~"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

struct ServerRow: View {
    let server: DevServer
    let onAskAgent: () -> Void
    let onShareTunnel: () -> Void
    let onManageTunnels: () -> Void
    let onKill: (_ force: Bool) -> Void

    private var preferences: Preferences { Preferences.shared }
    private var tunnels: TunnelManager { TunnelManager.shared }
    private var editorName: String { preferences.preferredIDEName }
    private var folderPath: String? {
        server.project?.rootPath ?? server.workingDirectory
    }
    private var showAsk: Bool { preferences.askAboutProcessEnabled }
    private var hasMenuActions: Bool { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(server.isOrphaned ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                    .help(server.isOrphaned ? "Possibly orphaned — parent process is gone" : "Listening")
                Text(server.processName)
                    .font(.system(.body, weight: .medium))
                if tunnels.isShared(server.port) {
                    Text("Shared")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.2), in: Capsule())
                        .foregroundStyle(.cyan)
                        .help("Public Cloudflare tunnel is active for this port")
                }
                if server.isOrphaned {
                    Text("Orphan")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("Parent shell/process is gone — this server may have been forgotten")
                }
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let uptime = server.formattedUptime(relativeTo: context.date) {
                        Text(uptime)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help("Process uptime")
                    }
                }
                Text(String(server.port))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                actionButtons
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

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                OpenActions.openInBrowser(server)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open localhost:\(String(server.port)) in browser")

            Menu {
                if showAsk {
                    Button("Ask about process") { onAskAgent() }
                }
                if tunnels.isShared(server.port) {
                    if showAsk { Divider() }
                    Button("Copy public URL") {
                        TunnelManager.shared.copyURL(for: server.port)
                    }
                    .disabled(TunnelManager.shared.tunnel(for: server.port)?.publicURL == nil)
                    Button("Manage tunnel") { onManageTunnels() }
                    Button("Stop sharing") {
                        TunnelManager.shared.stopShare(port: server.port)
                    }
                } else {
                    if showAsk { Divider() }
                    Button("Share via Cloudflare") { onShareTunnel() }
                }
                if let path = folderPath {
                    Divider()
                    Button("Reveal in Finder") { OpenActions.revealInFinder(path) }
                    Button("Open in \(editorName)") {
                        OpenActions.openInEditor(path)
                    }
                    Button("Open in Terminal") { OpenActions.openInTerminal(path) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .disabled(!hasMenuActions)

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
    }
}
