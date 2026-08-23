import SwiftUI

struct AgentMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    var text: String
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct AgentChatModal: View {
    let server: DevServer
    let onDismiss: () -> Void

    @State private var conversation: (any LocalAIConversation)?
    @State private var messages: [AgentMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var availabilityNote: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            if let availabilityNote {
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
        .onAppear(perform: bootstrap)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask about process")
                    .font(.system(size: 15, weight: .semibold))
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
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if isSending {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: isSending) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            Divider().opacity(0.5)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this process…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var canSend: Bool {
        !isSending && availabilityNote == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .assistant:
            HStack {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func bootstrap() {
        Task { @MainActor in
            let provider = AppleFoundationModelProvider()
            switch await provider.availability(modelID: nil) {
            case .available:
                do {
                    conversation = try await provider.makeConversation(
                        context: server.sanitizedAgentContext,
                        modelID: nil
                    )
                    messages = [
                        AgentMessage(
                            role: .system,
                            text: "Apple Intelligence has this process’s port, PID, command, and project context. Ask anything about it."
                        )
                    ]
                    inputFocused = true
                } catch {
                    availabilityNote = error.localizedDescription
                }
            case .unavailable(let error):
                availabilityNote = error.localizedDescription
            }
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let conversation, !prompt.isEmpty else { return }
        draft = ""
        messages.append(AgentMessage(role: .user, text: prompt))
        isSending = true

        Task { @MainActor in
            defer { isSending = false }
            do {
                let response = try await conversation.respond(to: prompt)
                messages.append(AgentMessage(role: .assistant, text: response))
            } catch {
                messages.append(AgentMessage(
                    role: .system,
                    text: error.localizedDescription
                ))
            }
        }
    }

    private func close() {
        let activeConversation = conversation
        conversation = nil
        Task { @MainActor in
            await activeConversation?.close()
            onDismiss()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                if isSending {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

#endif

/// Fallback when the app is running on an older macOS without Foundation Models.
struct AgentUnavailableModal: View {
    let server: DevServer
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about process")
                .font(.system(size: 15, weight: .semibold))
            Text("\(server.processName) · localhost:\(String(server.port))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Ask requires macOS 26 or later with Apple Intelligence.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
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
}
