import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh").font(.caption).foregroundColor(.secondary)
                Picker("Interval", selection: $settings.pollIntervalOverride) {
                    Text("Adaptive (recommended)").tag(0.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                .labelsHidden()
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications").font(.caption).foregroundColor(.secondary)
                Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                Toggle("75% usage", isOn: $settings.notify75)
                    .disabled(!settings.notificationsEnabled)
                Toggle("90% usage", isOn: $settings.notify90)
                    .disabled(!settings.notificationsEnabled)
                Toggle("95% usage", isOn: $settings.notify95)
                    .disabled(!settings.notificationsEnabled)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}
