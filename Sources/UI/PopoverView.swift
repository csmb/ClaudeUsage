import SwiftUI

/// Main popover content: usage cards + countdown timers + footer.
struct PopoverView: View {

    @EnvironmentObject private var state:    AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var now = Date()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let response = state.usageResponse {
                usageCards(response)
            } else if state.isLoading {
                loadingView
            } else {
                emptyView
            }
            if let err = state.error {
                errorBanner(err)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onReceive(timer) { t in now = t }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            if state.isLoading {
                ProgressView().scaleEffect(0.7)
            }
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Refresh now")

            SettingsLink {
                Image(systemName: "gear")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: - Usage Cards

    private func usageCards(_ response: UsageResponse) -> some View {
        VStack(spacing: 8) {
            UsageCard(
                label:    "5-Hour Window",
                usage:    response.usage.fiveHour,
                resetAt:  response.usage.fiveHour.resetAt,
                now:      now
            )
            UsageCard(
                label:    "7-Day Window",
                usage:    response.usage.sevenDay,
                resetAt:  response.usage.sevenDay.resetAt,
                now:      now
            )
            if let opus = response.usage.opus {
                UsageCard(
                    label:    "Opus",
                    usage:    opus,
                    resetAt:  opus.resetAt,
                    now:      now
                )
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading usage data…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private var emptyView: some View {
        Text("No data yet. Checking…")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .imageScale(.small)
            Text(message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let age = state.cacheAgeText {
                Text("Cached · \(age)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if let at = state.fetchedAt {
                Text("Updated \(at, style: .time)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - UsageCard

struct UsageCard: View {

    let label:   String
    let usage:   PeriodUsage
    let resetAt: Date?
    let now:     Date

    private var level: UtilizationLevel { UtilizationLevel(fraction: usage.fraction) }

    private var accentColor: Color {
        switch level {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(usage.percent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(accentColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accentColor)
                        .frame(width: geo.size.width * usage.fraction, height: 6)
                        .animation(.easeOut(duration: 0.4), value: usage.fraction)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(usage.used) / \(usage.limit)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let reset = resetAt {
                    CountdownView(targetDate: reset, now: now)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - CountdownView

struct CountdownView: View {

    let targetDate: Date
    let now:        Date

    private var remaining: TimeInterval { targetDate.timeIntervalSince(now) }

    var body: some View {
        if remaining > 0 {
            Text("Resets in \(formatted)")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            Text("Reset pending…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var formatted: String {
        let total  = Int(remaining)
        let hours  = total / 3600
        let mins   = (total % 3600) / 60
        let secs   = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, mins)
        } else if mins > 0 {
            return String(format: "%dm %02ds", mins, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}
