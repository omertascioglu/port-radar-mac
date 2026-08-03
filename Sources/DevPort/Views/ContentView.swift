import SwiftUI

/// Servers grouped by detected project (or System / Other buckets).
struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let framework: Framework?
    let rootPath: String?
    let servers: [DevServer]
}

struct ContentView: View {
    private var state = AppState.shared

    private var groups: [ProjectGroup] {
        var projects: [String: [DevServer]] = [:]
        var system: [DevServer] = []
        var other: [DevServer] = []

        for server in state.servers {
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
        .frame(width: 380)
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
                ForEach(groups) { group in
                    GroupHeader(group: group)
                    ForEach(group.servers) { server in
                        ServerRow(server: server)
                    }
                }
            }
        }
        // ScrollView collapses to zero height inside a MenuBarExtra window
        // unless given an explicit height, so estimate from the content.
        .frame(height: min(
            420,
            CGFloat(state.servers.count) * 47 + CGFloat(groups.count) * 27
        ))
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

struct GroupHeader: View {
    let group: ProjectGroup

    var body: some View {
        HStack(spacing: 5) {
            if let framework = group.framework {
                Image(systemName: framework.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(framework.rawValue)
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
    /// When non-nil, the row shows inline kill confirmation (true = force kill).
    @State private var confirmingForce: Bool?

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
                actionButtons
            }
            if let force = confirmingForce {
                confirmationBar(force: force)
            } else {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func confirmationBar(force: Bool) -> some View {
        HStack(spacing: 6) {
            if server.isSystemProcess {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("System process — macOS may relaunch it.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(force ? "Force kill immediately?" : "Stop this process?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(force ? "Force Kill" : "Stop") {
                let pid = server.pid
                if force {
                    ProcessActions.forceKill(pid: pid)
                } else {
                    Task { await ProcessActions.stop(pid: pid) }
                }
                confirmingForce = nil
            }
            .controlSize(.small)
            .tint(.red)
            Button("Cancel") {
                confirmingForce = nil
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
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
                Button("Copy Command") { OpenActions.copyCommand(server) }
                    .disabled(server.command == nil)
                if let path = server.project?.rootPath ?? server.workingDirectory {
                    Button("Reveal in Finder") { OpenActions.revealInFinder(path) }
                    Button("Open in Cursor") { OpenActions.openInCursor(path) }
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

            Button {
                confirmingForce = false
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop gracefully — asks the process to quit (SIGTERM), force kills after 4 s if it doesn't")

            Button {
                confirmingForce = true
            } label: {
                Image(systemName: "bolt.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Force kill immediately (SIGKILL) — no chance to clean up")
        }
    }
}
