import SwiftUI

struct SettingsModal: View {
    @Bindable private var preferences = Preferences.shared
    @State private var ollamaSettings = OllamaSettingsModel()
    let onDismiss: () -> Void

    private let ollamaDownloadURL = URL(
        string: "https://ollama.com/download/mac"
    )!

    private var showsOllamaControls: Bool {
        preferences.askAboutProcessEnabled
            && preferences.localAIProviderPreference.usesOllamaControls
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 14)

            VStack(spacing: 12) {
                settingsGroup {
                    settingsRow("Refresh interval") {
                        Picker("", selection: $preferences.pollingIntervalSeconds) {
                            Text("1s").tag(1.0)
                            Text("2.5s").tag(2.5)
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                settingsGroup {
                    settingsRow("Launch at login") {
                        Toggle("", isOn: $preferences.launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                settingsGroup {
                    settingsRow("Notify on new port") {
                        Toggle("", isOn: $preferences.notificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().padding(.leading, 12)

                    settingsRow("Hide system processes") {
                        Toggle("", isOn: $preferences.hideSystemProcesses)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().padding(.leading, 12)

                    settingsRow("Ask about process") {
                        Toggle("", isOn: $preferences.askAboutProcessEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if preferences.askAboutProcessEnabled {
                        Divider().padding(.leading, 12)

                        settingsRow("AI provider") {
                            Picker(
                                "AI provider",
                                selection: $preferences.localAIProviderPreference
                            ) {
                                ForEach(LocalAIProviderPreference.allCases) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        if preferences.localAIProviderPreference.usesOllamaControls {
                            Divider().padding(.leading, 12)

                            settingsRow("Ollama model") {
                                switch ollamaSettings.state {
                                case .ready(let models) where !models.isEmpty:
                                    Picker(
                                        "Ollama model",
                                        selection: $preferences.ollamaModelID
                                    ) {
                                        Text("Choose…").tag("")
                                        ForEach(models) { model in
                                            Text(model.id).tag(model.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 170)
                                default:
                                    Text("None")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider().padding(.leading, 12)

                            ollamaStatus
                        }

                        Divider().padding(.leading, 12)

                        Text(
                            "Chat stays on this Mac. Cloud and remote Ollama models are excluded."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }

                if let launchError = preferences.launchAtLoginError {
                    Text(launchError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                settingsGroup {
                    settingsRow("Preferred editor") {
                        let editors = IDEDetector.installed()
                        if editors.isEmpty {
                            Text("None found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $preferences.preferredIDEBundleID) {
                                ForEach(editors) { editor in
                                    Text(editor.name).tag(editor.bundleIdentifier)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }

                settingsGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Port range")
                            .font(.system(size: 13))
                        HStack(spacing: 8) {
                            TextField("Min", value: $preferences.portRangeMin, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Text("–")
                                .foregroundStyle(.secondary)
                            TextField("Max", value: $preferences.portRangeMax, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Spacer()
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 12)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Process allowlist")
                            .font(.system(size: 13))
                        TextField("node, python, vite…", text: $preferences.processAllowlist)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Text("Comma-separated. Empty shows all matching the other filters.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .onAppear {
                preferences.refreshLaunchAtLogin()
                updateOllamaRefresh()
            }
            .onChange(of: preferences.askAboutProcessEnabled) {
                updateOllamaRefresh()
            }
            .onChange(of: preferences.localAIProviderPreference) {
                updateOllamaRefresh()
            }
            .onDisappear {
                ollamaSettings.cancelRefresh()
            }

            Divider()
                .padding(.top, 16)

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 352)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .white.opacity(0.16), radius: 24, y: 0)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private var ollamaStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if ollamaSettings.state == .loading {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(ollamaSettings.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if ollamaSettings.state == .notRunning {
                    Button("Open Ollama") {
                        ollamaSettings.openOllamaAndRetry(
                            selectedModelID: preferences.ollamaModelID
                        )
                    }
                    .controlSize(.small)
                }
            }

            if ollamaSettings.showsDownloadLink {
                HStack(spacing: 5) {
                    Text("Install Ollama to use a local model.")
                    Link("Download Ollama", destination: ollamaDownloadURL)
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func updateOllamaRefresh() {
        guard showsOllamaControls else {
            ollamaSettings.cancelRefresh()
            return
        }

        ollamaSettings.refresh(
            selectedModelID: preferences.ollamaModelID
        )
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
