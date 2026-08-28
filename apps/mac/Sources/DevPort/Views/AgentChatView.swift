// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution.
import SwiftUI

struct AgentChatModal: View {
    private static let streamingRowID = "streaming"

    let server: DevServer
    let onDismiss: () -> Void

    @State private var model: AgentChatModel
    @FocusState private var inputFocused: Bool

    init(server: DevServer, onDismiss: @escaping () -> Void) {
        self.server = server
        self.onDismiss = onDismiss
        _model = State(initialValue: AgentChatModel(
            server: server,
            resolver: .live,
            preference: Preferences.shared.localAIProviderPreference,
            ollamaModelID: Preferences.shared.ollamaModelID
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            if let availabilityNote = model.availabilityNote {
                unavailableBody(availabilityNote)
            } else {
                chatBody
            }
        }
        .frame(width: 340, height: 420)
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
        .task {
            await model.bootstrap()
            guard !Task.isCancelled, model.availabilityNote == nil else {
                return
            }
            inputFocused = true
        }
        .onDisappear {
            model.beginClose()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Ask about process")
                        .font(.system(size: 15, weight: .semibold))
                    if let badge = model.badgeText {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Color.green.opacity(0.14),
                                in: Capsule()
                            )
                            .foregroundStyle(.green)
                    }
                }
                Text("\(server.processName) · localhost:\(String(server.port)) · pid \(String(server.pid))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func unavailableBody(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
    }

    private var chatBody: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if model.isSending {
                            streamingRow
                                .id(Self.streamingRowID)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: model.streamRevision) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: model.isSending) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            Divider().opacity(0.5)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Ask about this process…",
                    text: $model.draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(model.send)

                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            model.canSend
                                ? Color.accentColor
                                : Color.secondary.opacity(0.4)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
                .help("Send")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Text("Offline — data never leaves this Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    /// Replaces the passive thinking row: the same progress indicator now sits
    /// next to the control that stops the streaming reply.
    private var streamingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Button(action: model.stopGeneration) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8))
                    Text("Stop")
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop response")
            .help("Stop response")
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AgentMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.accentColor.opacity(0.22),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )
            }
        case .assistant where message.text.isEmpty:
            // The streaming placeholder stays invisible until its first chunk.
            EmptyView()
        case .assistant:
            HStack {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(0.07),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )
                    .textSelection(.enabled)
                Spacer(minLength: 24)
            }
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func close() {
        model.beginClose()
        onDismiss()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                if model.isSending {
                    proxy.scrollTo(Self.streamingRowID, anchor: .bottom)
                } else if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
