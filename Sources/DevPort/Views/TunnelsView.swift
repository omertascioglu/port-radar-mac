import AppKit
import SwiftUI

struct TunnelsModal: View {
    let focusPort: Int?
    let onDismiss: () -> Void
    private var tunnels = TunnelManager.shared

    init(focusPort: Int?, onDismiss: @escaping () -> Void) {
        self.focusPort = focusPort
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            if tunnels.tunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(tunnels.tunnels) { tunnel in
                            tunnelRow(tunnel)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 280)
            }

            Divider().opacity(0.5)
            footerNote
        }
        .frame(width: 340)
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
        .onAppear {
            if let focusPort, tunnels.tunnel(for: focusPort) == nil {
                // Sheet opened from Share before start finished inserting — fine.
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnels")
                    .font(.system(size: 15, weight: .semibold))
                Text("Cloudflare quick tunnels · public while active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No active tunnels")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Share a port from the ⋯ menu. On first share, Port Radar downloads the Cloudflare helper into Application Support — no Homebrew needed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tunnelRow(_ tunnel: PortTunnel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tunnel.processName)
                    .font(.system(.body, weight: .medium))
                Text(":\(String(tunnel.port))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                statusChip(tunnel.status)
            }

            switch tunnel.status {
            case .downloading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading Cloudflare helper…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .starting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting tunnel…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .live:
                if let url = tunnel.publicURL {
                    Text(url.absoluteString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("Copy URL") {
                            TunnelManager.shared.copyURL(for: tunnel.port)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Open") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("Stop", role: .destructive) {
                            TunnelManager.shared.stopShare(port: tunnel.port)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Dismiss") {
                        TunnelManager.shared.stopShare(port: tunnel.port)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(focusPort == tunnel.port ? 0.10 : 0.06))
        )
    }

    @ViewBuilder
    private func statusChip(_ status: TunnelStatus) -> some View {
        switch status {
        case .downloading:
            Text("Download")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2), in: Capsule())
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2), in: Capsule())
                .foregroundStyle(.secondary)
        case .live:
            Text("Live")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        case .failed:
            Text("Failed")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    private var footerNote: some View {
        HStack {
            if !tunnels.tunnels.isEmpty {
                Button("Stop all", role: .destructive) {
                    TunnelManager.shared.stopAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
