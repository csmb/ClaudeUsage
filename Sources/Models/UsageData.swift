import Foundation

// MARK: - API Response

struct UsageResponse: Codable {
    let fiveHour:     UsageWindow?
    let sevenDay:     UsageWindow?
    let sevenDayOpus: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour     = "five_hour"
        case sevenDay     = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

struct UsageWindow: Codable {
    let utilization: Double   // 0–100 percentage
    let resetsAt:    Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var fraction: Double { min(utilization / 100.0, 1.0) }
    var percent:  Int    { Int(utilization.rounded()) }
}

// MARK: - Cached Snapshot

struct CachedUsage: Codable {
    let response:  UsageResponse
    let fetchedAt: Date

    var ageMinutes: Int { Int(Date().timeIntervalSince(fetchedAt) / 60) }
    var isStale:    Bool { Date().timeIntervalSince(fetchedAt) > 24 * 3600 }
}

// MARK: - Utilization Level (drives polling cadence + icon color)

enum UtilizationLevel {
    case low       // < 50 %
    case medium    // 50–74 %
    case high      // 75–89 %
    case critical  // >= 90 %

    init(fraction: Double) {
        switch fraction {
        case ..<0.50:       self = .low
        case 0.50..<0.75:   self = .medium
        case 0.75..<0.90:   self = .high
        default:            self = .critical
        }
    }

    var pollInterval: TimeInterval {
        switch self {
        case .low:      return 300
        case .medium:   return 120
        case .high:     return 60
        case .critical: return 30
        }
    }
}
