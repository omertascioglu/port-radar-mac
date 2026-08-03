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
                }
            }
            .padding(.horizontal, 16)

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
        .frame(width: 300)
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
