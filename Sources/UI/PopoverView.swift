import SwiftUI
import Charts
import Combine

/// Main popover content: usage cards + countdown timers + footer.
struct PopoverView: View {

    @EnvironmentObject private var state:    AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
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
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 500)
        .onReceive(timer) { t in now = t }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Claude Usage")
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .help("Open usage in browser")
            Spacer()
            if state.isLoading {
                SpinnerView(size: 12)
            }
            Button {
                Task { await state.refresh() }
            } label: {
                if state.canRefresh {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                } else {
                    Text("\(state.cooldownRemaining)s")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!state.canRefresh)
            .help(state.canRefresh ? "Refresh now" : "Wait \(state.cooldownRemaining)s before refreshing")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
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
            if let w = response.fiveHour {
                let lastHourData = chartPoints(field: \.fiveHourPct, hours: 1)
                if lastHourData.count >= 2 {
                    UsageCard(
                        label:         "Last Hour",
                        window:        w,
                        now:           now,
                        chartData:     lastHourData,
                        windowHours:   1,
                        showCountdown: false
                    )
                }
                UsageCard(
                    label:       "5 Hour Window",
                    window:      w,
                    now:         now,
                    chartData:   chartPoints(field: \.fiveHourPct, hours: 5),
                    windowHours: 5
                )
            }
            if let w = response.sevenDay {
                UsageCard(
                    label:       "7 Day Window",
                    window:      w,
                    now:         now,
                    chartData:   chartPoints(field: \.sevenDayPct, hours: 168),
                    windowHours: 168
                )
            }
            if let w = response.sevenDayOpus {
                UsageCard(
                    label:       "Opus (7 Day)",
                    window:      w,
                    now:         now,
                    chartData:   chartPoints(field: \.sevenDayOpusPct, hours: 168),
                    windowHours: 168
                )
            }
        }
    }

    private func chartPoints(
        field: KeyPath<UsageDataPoint, Double?>,
        hours: Double
    ) -> [(timestamp: Date, pct: Double)] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return state.usageHistory
            .filter { $0.timestamp >= cutoff }
            .map { pt in
                (timestamp: pt.timestamp, pct: pt[keyPath: field] ?? 0.0)
            }
    }

    // MARK: - States

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                SpinnerView(size: 20)
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
            if let status = state.statusLine {
                Text(status.text)
                    .font(.caption2)
                    .foregroundColor(status.isWarning ? .orange : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

    let label:         String
    let window:        UsageWindow
    let now:           Date
    let chartData:     [(timestamp: Date, pct: Double)]
    let windowHours:   Double
    var showCountdown: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    private var level: UtilizationLevel { UtilizationLevel(fraction: window.fraction) }

    private var accentColor: Color {
        let dark = colorScheme == .dark
        switch level {
        case .low:
            return dark ? Color(red: 0.133, green: 0.773, blue: 0.369)
                        : Color(red: 0.086, green: 0.396, blue: 0.204)
        case .medium:
            return dark ? Color(red: 0.984, green: 0.749, blue: 0.141)
                        : Color(red: 0.573, green: 0.251, blue: 0.055)
        case .high:
            return dark ? Color(red: 0.984, green: 0.573, blue: 0.235)
                        : Color(red: 0.604, green: 0.204, blue: 0.071)
        case .critical:
            return dark ? Color(red: 0.973, green: 0.443, blue: 0.443)
                        : Color(red: 0.600, green: 0.106, blue: 0.106)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(window.percent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(accentColor)
            }

            usageChart

            if showCountdown {
                HStack {
                    Spacer()
                    if let reset = window.resetsAt {
                        CountdownView(targetDate: reset, now: now)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Time-Series Chart

    @ViewBuilder
    private var usageChart: some View {
        if chartData.isEmpty {
            Text("No history yet — data accumulates as the app polls.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else {
            UsageChartView(
                data: chartData,
                domainStart: now.addingTimeInterval(-windowHours * 3600),
                domainEnd: now,
                accentColor: accentColor,
                height: 60,
                windowHours: windowHours,
                compact: windowHours <= 1
            )
        }
    }
}

// MARK: - UsageChartView

struct UsageChartView: View {

    let data: [(timestamp: Date, pct: Double)]
    let domainStart: Date
    let domainEnd: Date
    let accentColor: Color
    let height: CGFloat
    let windowHours: Double
    let compact: Bool

    @State private var hoverInfo: (date: Date, value: Double)?

    private var usageGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .yellow, location: 0.5),
                .init(color: .orange, location: 0.75),
                .init(color: .red, location: 1.0),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private static func colorForPct(_ pct: Double) -> Color {
        let t = min(max(pct / 100.0, 0), 1)
        if t < 0.5 {
            return Color.green.mix(with: .yellow, by: t / 0.5)
        } else if t < 0.75 {
            return Color.yellow.mix(with: .orange, by: (t - 0.5) / 0.25)
        } else {
            return Color.orange.mix(with: .red, by: (t - 0.75) / 0.25)
        }
    }

    var body: some View {
        if data.isEmpty {
            Text("No history yet")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: height)
        } else {
            baseChart
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)%").font(.caption2)
                            }
                        }
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    }
                }
                .frame(height: height)
        }
    }

    private var baseChart: some View {
        Chart {
            ForEach(data, id: \.timestamp) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage %", point.pct)
                )
                .foregroundStyle(usageGradient.opacity(0.2))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage %", point.pct)
                )
                .foregroundStyle(usageGradient)
                .interpolationMethod(.catmullRom)
            }

            if let latest = data.last {
                PointMark(
                    x: .value("Time", latest.timestamp),
                    y: .value("Usage %", latest.pct)
                )
                .foregroundStyle(Self.colorForPct(latest.pct))
                .symbolSize(30)
            }

            if let hover = hoverInfo {
                RuleMark(x: .value("Hover", hover.date))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Time", hover.date),
                    y: .value("Usage %", hover.value)
                )
                .foregroundStyle(Self.colorForPct(hover.value))
                .symbolSize(40)
                .annotation(position: hover.value > 75 ? .bottom : .top) {
                    Text("\(Int(hover.value.rounded()))%")
                        .font(.caption2.monospacedDigit().bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(3)
                        .shadow(color: .black.opacity(0.1), radius: 1)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domainStart...domainEnd)
        .chartXAxis {
            if windowHours <= 1 {
                AxisMarks(values: [
                    domainEnd,
                    domainEnd.addingTimeInterval(-15 * 60),
                    domainEnd.addingTimeInterval(-30 * 60),
                    domainEnd.addingTimeInterval(-45 * 60),
                    domainStart
                ]) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let mins = Int(domainEnd.timeIntervalSince(date) / 60)
                            Text(mins == 0 ? "now" : mins == 60 ? "1h" : "\(mins)m")
                                .font(.caption2)
                        }
                    }
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                }
            } else if windowHours <= 24 {
                AxisMarks(preset: .automatic, values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let hour = Calendar.current.component(.hour, from: date)
                            let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
                            let ap = hour < 12 ? "a" : "p"
                            Text("\(h12)\(ap)")
                                .font(.caption2)
                        }
                    }
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                }
            } else {
                AxisMarks(preset: .automatic, values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month().day())
                        .font(.caption2)
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let date: Date = proxy.value(atX: location.x) else {
                                hoverInfo = nil
                                return
                            }
                            guard let nearest = data.min(by: {
                                abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
                            }) else {
                                hoverInfo = nil
                                return
                            }
                            hoverInfo = (date: nearest.timestamp, value: nearest.pct)
                        case .ended:
                            hoverInfo = nil
                        }
                    }
            }
        }
    }
}

// MARK: - SpinnerView

struct SpinnerView: View {
    let size: CGFloat
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .resizable()
            .frame(width: size, height: size)
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
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
        let total = Int(remaining)
        let days  = total / 86400
        let hours = (total % 86400) / 3600
        let mins  = (total % 3600) / 60
        let secs  = total % 60
        if days > 0 {
            return "\(days)d \(hours)h \(mins)m"
        } else if hours > 0 {
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        } else if mins > 0 {
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        } else {
            return "\(secs)s"
        }
    }
}
