import Foundation

// MARK: - API Response

struct UsageResponse: Codable {
    let resetAt: Date
    let usage: UsagePeriods

    enum CodingKeys: String, CodingKey {
        case resetAt = "reset_at"
        case usage
    }
}

struct UsagePeriods: Codable {
    let fiveHour: PeriodUsage
    let sevenDay: PeriodUsage
    let opus: PeriodUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case opus
    }
}

struct PeriodUsage: Codable {
    let used: Int
    let limit: Int
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case used
        case limit
        case resetAt = "reset_at"
    }

    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(Double(used) / Double(limit), 1.0)
    }

    var percent: Int {
        Int(fraction * 100)
    }
}

// MARK: - Cached Snapshot

struct CachedUsage: Codable {
    let response: UsageResponse
    let fetchedAt: Date

    var ageMinutes: Int {
        Int(Date().timeIntervalSince(fetchedAt) / 60)
    }

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 24 * 3600
    }
}

// MARK: - Utilization Level (drives polling cadence + icon color)

enum UtilizationLevel {
    case low       // < 50%
    case medium    // 50–74%
    case high      // 75–89%
    case critical  // >= 90%

    init(fraction: Double) {
        switch fraction {
        case ..<0.50: self = .low
        case 0.50..<0.75: self = .medium
        case 0.75..<0.90: self = .high
        default: self = .critical
        }
    }

    /// Polling interval in seconds
    var pollInterval: TimeInterval {
        switch self {
        case .low:      return 300  // 5 min
        case .medium:   return 120  // 2 min
        case .high:     return 60   // 1 min
        case .critical: return 30   // 30 s
        }
    }

    var colorName: String {
        switch self {
        case .low:      return "green"
        case .medium:   return "yellow"
        case .high:     return "orange"
        case .critical: return "red"
        }
    }
}
