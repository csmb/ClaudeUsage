import Foundation

/// Synthetic usage data for `--demo` runs.
///
/// Deterministic — no randomness anywhere — so the same scenario always draws
/// the same curves and screenshots stay comparable between runs.
enum DemoData {

    struct Snapshot {
        let response: UsageResponse
        let history:  [UsageDataPoint]
    }

    private static let fiveHourWindow: TimeInterval = 5 * 3600
    private static let sevenDayWindow: TimeInterval = 7 * 86400

    // MARK: - Scenarios

    /// Headline percentages plus how much time is left on each window.
    /// Heavier usage sits closer to its reset — that's what a real heavy day
    /// looks like, and it keeps the countdowns believable.
    private struct Recipe {
        let fiveHour: Double
        let sevenDay: Double
        let opus:     Double
        let fiveHourResetsIn: TimeInterval
        let sevenDayResetsIn: TimeInterval
    }

    private static func recipe(for scenario: DemoMode.Scenario) -> Recipe {
        switch scenario {
        case .healthy:
            return Recipe(fiveHour: 18, sevenDay: 24, opus: 31,
                          fiveHourResetsIn: 4 * 3600 + 2 * 60,
                          sevenDayResetsIn: 5 * 86400 + 11 * 3600)
        case .mixed:
            return Recipe(fiveHour: 62, sevenDay: 38, opus: 81,
                          fiveHourResetsIn: 2 * 3600 + 14 * 60,
                          sevenDayResetsIn: 4 * 86400 + 6 * 3600)
        case .heavy:
            return Recipe(fiveHour: 94, sevenDay: 88, opus: 97,
                          fiveHourResetsIn: 41 * 60,
                          sevenDayResetsIn: 86400 + 3 * 3600)
        }
    }

    // MARK: - Public API

    static func snapshot(for scenario: DemoMode.Scenario, now: Date = Date()) -> Snapshot {
        let r = recipe(for: scenario)
        let fiveHourResets = now.addingTimeInterval(r.fiveHourResetsIn)
        let sevenDayResets = now.addingTimeInterval(r.sevenDayResetsIn)

        let response = UsageResponse(
            fiveHour:     UsageWindow(utilization: r.fiveHour, resetsAt: fiveHourResets),
            sevenDay:     UsageWindow(utilization: r.sevenDay, resetsAt: sevenDayResets),
            sevenDayOpus: UsageWindow(utilization: r.opus,     resetsAt: sevenDayResets)
        )

        return Snapshot(
            response: response,
            history:  history(
                recipe:      r,
                now:         now,
                windowStart: fiveHourResets.addingTimeInterval(-fiveHourWindow)
            )
        )
    }

    // MARK: - History

    /// Sampled densely over the last five hours (the 5h and Last Hour charts
    /// need smooth lines) and coarsely before that (the 7d chart only needs
    /// shape).
    private static func history(recipe r: Recipe, now: Date, windowStart: Date) -> [UsageDataPoint] {
        var timestamps: [Date] = []

        var t = now.addingTimeInterval(-sevenDayWindow)
        let fineFrom = now.addingTimeInterval(-fiveHourWindow)
        while t < fineFrom {
            timestamps.append(t)
            t = t.addingTimeInterval(30 * 60)
        }
        t = fineFrom
        while t < now {
            timestamps.append(t)
            t = t.addingTimeInterval(3 * 60)
        }
        timestamps.append(now)

        return timestamps.map { ts in
            UsageDataPoint(
                id:              UUID(),
                timestamp:       ts,
                fiveHourPct:     rollingFiveHour(at: ts, now: now, windowStart: windowStart, target: r.fiveHour),
                sevenDayPct:     rollingSevenDay(at: ts, now: now, target: r.sevenDay, dips: 7),
                sevenDayOpusPct: rollingSevenDay(at: ts, now: now, target: r.opus,     dips: 5)
            )
        }
    }

    /// A rolling seven-day window: trends upward across the week and dips
    /// through quiet stretches as older usage ages out.
    ///
    /// `dips` is an integer so every dip term is zero at p = 1 — which makes
    /// the curve land exactly on `target` at `now`, matching the headline
    /// number and the endpoint dot on the chart.
    private static func rollingSevenDay(at t: Date, now: Date, target: Double, dips: Double) -> Double {
        let p = 1 - clamp(now.timeIntervalSince(t) / sevenDayWindow)   // 0 = a week ago, 1 = now
        let trend = 0.35 + 0.65 * p
        let quiet = 0.09 * abs(sin(.pi * dips * p))
              + 0.045 * abs(sin(.pi * 2 * p))
        return target * (trend - quiet)
    }

    /// A five-hour window: climbs in bursts, drops to zero on reset. Earlier
    /// windows keep their own peaks so the chart shows a real sawtooth rather
    /// than one lonely ramp.
    private static func rollingFiveHour(at t: Date, now: Date, windowStart: Date, target: Double) -> Double {
        if t >= windowStart {
            let elapsedNow = now.timeIntervalSince(windowStart)
            guard elapsedNow > 0 else { return target }
            return target * burst(clamp(t.timeIntervalSince(windowStart) / elapsedNow))
        }
        let index = Int(floor(windowStart.timeIntervalSince(t) / fiveHourWindow))
        let start = windowStart.addingTimeInterval(-Double(index + 1) * fiveHourWindow)
        let progress = clamp(t.timeIntervalSince(start) / fiveHourWindow)
        return previousPeak(index: index, target: target) * burst(progress)
    }

    /// Maps 0 → 0 and 1 → 1, monotonically, in four bursts-and-plateaus.
    /// The derivative is `1 + 0.7·cos(…)`, which never reaches zero, so usage
    /// never appears to run backwards inside a window.
    private static func burst(_ s: Double) -> Double {
        let k = 5.0
        return s + 0.85 * sin(2 * .pi * k * s) / (2 * .pi * k)
    }

    private static func previousPeak(index: Int, target: Double) -> Double {
        let factors = [0.86, 0.52, 0.97, 0.41, 0.73, 0.63]
        return min(98, target * factors[index % factors.count] * 1.15)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
