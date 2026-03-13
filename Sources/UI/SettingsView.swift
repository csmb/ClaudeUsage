import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Display mode", selection: $settings.displayModeRaw) {
                    ForEach(AppSettings.DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section("Refresh") {
                Picker("Interval", selection: $settings.pollIntervalOverride) {
                    Text("Adaptive (recommended)").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            }
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                Toggle("75% usage", isOn: $settings.notify75)
                    .disabled(!settings.notificationsEnabled)
                Toggle("90% usage", isOn: $settings.notify90)
                    .disabled(!settings.notificationsEnabled)
                Toggle("95% usage", isOn: $settings.notify95)
                    .disabled(!settings.notificationsEnabled)
            }
            Section("System") {
                Button("Manage Login Items…") {
                    if #available(macOS 13.0, *) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
    }
}
