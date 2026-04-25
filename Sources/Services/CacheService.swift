import Foundation

/// Persists the last-known UsageResponse to disk so the app can display
/// stale data when the network is unavailable.
///
/// Cache location: ~/Library/Caches/<bundleID>/usage_cache.json
/// TTL: 24 hours (stale entries are automatically discarded on read)

final class CacheService {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Init

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = full.date(from: str) { return d }
            let basic = ISO8601DateFormatter()
            if let d = basic.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Cannot parse date: \(str)"
            )
        }
    }

    // MARK: - Public API

    func save(_ response: UsageResponse) {
        let snapshot = CachedUsage(response: response, fetchedAt: Date())
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    func load() -> CachedUsage? {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let snapshot = try? decoder.decode(CachedUsage.self, from: data),
            !snapshot.isStale
        else { return nil }
        return snapshot
    }

    // MARK: - Private

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.claudeusage"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage_cache.json")
    }
}
