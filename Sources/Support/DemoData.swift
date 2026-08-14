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
        /// Bursts of activity per window. A heavy day is choppier: more
        /// sessions, each taking a bigger bite.
        let bursts: Double
    }

    private static func recipe(for scenario: DemoMode.Scenario) -> Recipe {
        switch scenario {
        case .healthy:
            return Recipe(fiveHour: 18, sevenDay: 24, opus: 31,
                          fiveHourResetsIn: 4 * 3600 + 2 * 60,
                          sevenDayResetsIn: 5 * 86400 + 11 * 3600,
                          bursts: 3)
        case .mixed:
            return Recipe(fiveHour: 62, sevenDay: 38, opus: 81,
                          fiveHourResetsIn: 2 * 3600 + 14 * 60,
                          sevenDayResetsIn: 4 * 86400 + 6 * 3600,
                          bursts: 5)
        case .heavy:
            return Recipe(fiveHour: 94, sevenDay: 88, opus: 97,
                          fiveHourResetsIn: 41 * 60,
                          sevenDayResetsIn: 86400 + 3 * 3600,
                          bursts: 9)
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
                recipe:         r,
                now:            now,
                fiveHourResets: fiveHourResets,
                sevenDayResets: sevenDayResets
            )
        )
    }

    // MARK: - History

    /// Sampled densely over the last five hours (the 5h and Last Hour charts
    /// need smooth lines) and coarsely before that (the 7d chart only needs
    /// shape).
    private static func history(
        recipe r: Recipe,
        now: Date,
        fiveHourResets: Date,
        sevenDayResets: Date
    ) -> [UsageDataPoint] {
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
                id:        UUID(),
                timestamp: ts,
                fiveHourPct: accumulated(
                    at: ts, now: now,
                    resetsAt: fiveHourResets, length: fiveHourWindow,
                    target: r.fiveHour, bursts: r.bursts,
                    earlierPeaks: [0.86, 0.52, 0.97, 0.41, 0.73, 0.63]
                ),
                sevenDayPct: accumulated(
                    at: ts, now: now,
                    resetsAt: sevenDayResets, length: sevenDayWindow,
                    target: r.sevenDay, bursts: r.bursts,
                    earlierPeaks: [0.78, 0.61]
                ),
                // Fewer, larger bites than the overall quota, so the Opus chart
                // doesn't trace the same line as the 7-day one.
                sevenDayOpusPct: accumulated(
                    at: ts, now: now,
                    resetsAt: sevenDayResets, length: sevenDayWindow,
                    target: r.opus, bursts: max(2, r.bursts - 3),
                    earlierPeaks: [0.66, 0.83]
                )
            )
        }
    }

    /// Usage within a quota window only ever accumulates — it never falls back
    /// — and drops to zero when the window resets. All three windows share this
    /// shape; only their length and reset time differ.
    private static func accumulated(
        at t: Date,
        now: Date,
        resetsAt: Date,
        length: TimeInterval,
        target: Double,
        bursts: Double,
        earlierPeaks: [Double]
    ) -> Double {
        let windowStart = resetsAt.addingTimeInterval(-length)

        if t >= windowStart {
            // Normalised against elapsed-so-far rather than the full window, so
            // the curve lands exactly on `target` at `now` — matching the
            // headline number and the endpoint dot on the chart.
            let elapsed = now.timeIntervalSince(windowStart)
            guard elapsed > 0 else { return target }
            return target * burst(clamp(t.timeIntervalSince(windowStart) / elapsed), count: bursts)
        }

        // Earlier windows: the same climb, to their own peak, before the reset.
        let index = Int(floor(windowStart.timeIntervalSince(t) / length))
        let start = windowStart.addingTimeInterval(-Double(index + 1) * length)
        let peak  = min(98, target * earlierPeaks[index % earlierPeaks.count] * 1.15)
        return peak * burst(clamp(t.timeIntervalSince(start) / length), count: bursts)
    }

    /// Relative size of each burst, cycled. Deliberately lopsided: evenly
    /// sized steps read as a synthetic ramp, whereas a long session next to a
    /// couple of small ones reads as somebody actually working.
    private static let burstWeights: [Double] = [
        1.0, 0.35, 1.6, 0.2, 0.9, 1.35, 0.5, 1.8, 0.7, 1.15, 0.3, 1.45
    ]

    /// Maps 0 → 0 and 1 → 1 monotonically, as `count` bursts of work separated
    /// by plateaus where nothing is being spent.
    ///
    /// Each burst climbs over the first 55% of its slot and then holds. Sized
    /// from `burstWeights`, so the steps are uneven; normalising by their total
    /// keeps the curve landing exactly on 1 at s = 1.
    private static func burst(_ s: Double, count: Double) -> Double {
        let n = max(1, Int(count))
        let weights = (0..<n).map { burstWeights[$0 % burstWeights.count] }
        let total = weights.reduce(0, +)

        let slot  = min(Int(clamp(s) * Double(n)), n - 1)
        let local = clamp(s) * Double(n) - Double(slot)
        let ramp  = smoothstep(min(local / 0.55, 1))

        let spent = weights[0..<slot].reduce(0, +) + weights[slot] * ramp
        return spent / total
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
