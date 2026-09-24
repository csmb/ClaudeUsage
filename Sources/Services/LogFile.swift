import Foundation

/// An append-only text log in ~/Library/Caches/<bundle id>/. Each line starts
/// with a UTC timestamp; once the file passes `maxBytes` it is cut back to its
/// newest `keepLines` lines, so it can't grow without bound.
///
/// Nonisolated: the lifecycle log writes to it from a signal handler that runs
/// off the main thread.
nonisolated struct LogFile {
    let url: URL
    private let maxBytes: Int
    private let keepLines: Int

    /// A log called `name` in the app's caches directory.
    init(named name: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClaudeUsage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(url: dir.appendingPathComponent(name))
    }

    init(url: URL, maxBytes: Int = 64 * 1024, keepLines: Int = 500) {
        self.url = url
        self.maxBytes = maxBytes
        self.keepLines = keepLines
    }

    func append(_ message: String, at date: Date = Date()) {
        let line = Data("\(Self.timestamp(date)) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        } else {
            try? line.write(to: url)
        }
        trimIfNeeded()
    }

    /// The log's lines, oldest first; empty if nothing has been logged yet.
    func lines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let kept = lines().suffix(keepLines).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestamp(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }
}
