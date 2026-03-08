import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .padding(16)
        .frame(width: 380, height: 260)
        .environmentObject(settings)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Interval", selection: $settings.pollIntervalOverride) {
                    Text("Adaptive (recommended)").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications Tab

private struct NotificationsTab: View {

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
            }
            Section("Alert thresholds") {
                Toggle("75% usage", isOn: $settings.notify75)
                    .disabled(!settings.notificationsEnabled)
                Toggle("90% usage", isOn: $settings.notify90)
                    .disabled(!settings.notificationsEnabled)
                Toggle("95% usage", isOn: $settings.notify95)
                    .disabled(!settings.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance Tab

private struct AppearanceTab: View {

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
        }
        .formStyle(.grouped)
    }
}
