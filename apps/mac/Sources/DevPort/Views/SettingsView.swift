import SwiftUI

struct SettingsModal: View {
    @Bindable private var preferences = Preferences.shared
    let onDismiss: () -> Void

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
            .onAppear { preferences.refreshLaunchAtLogin() }

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
        .frame(width: 320)
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
