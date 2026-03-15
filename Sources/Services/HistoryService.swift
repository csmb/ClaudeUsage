import Foundation

/// Persists a rolling 7-day log of UsageDataPoints to disk.
///
/// Storage location: ~/Library/Caches/<bundleID>/usage_history.json
final class HistoryService {

    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private(set) var points: [UsageDataPoint] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = full.date(from: str) { return date }
            let basic = ISO8601DateFormatter()
            if let date = basic.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Cannot parse date: \(str)"
            )
        }
        return d
    }()

    // MARK: - Init

    init() {
        points = loadFromDisk().filter {
            Date().timeIntervalSince($0.timestamp) <= Self.maxAge
        }
    }

    // MARK: - Public API

    func append(from response: UsageResponse) {
        let point = UsageDataPoint(
            id:              UUID(),
            timestamp:       Date(),
            fiveHourPct:     response.fiveHour?.utilization,
            sevenDayPct:     response.sevenDay?.utilization,
            sevenDayOpusPct: response.sevenDayOpus?.utilization
        )
        points.append(point)
        points = points.filter {
            Date().timeIntervalSince($0.timestamp) <= Self.maxAge
        }
        saveToDisk()
    }

    // MARK: - Private

    private func loadFromDisk() -> [UsageDataPoint] {
        guard
            let data    = try? Data(contentsOf: historyURL),
            let decoded = try? decoder.decode([UsageDataPoint].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveToDisk() {
        guard let data = try? encoder.encode(points) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private var historyURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.claudeusage"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage_history.json")
    }
}
