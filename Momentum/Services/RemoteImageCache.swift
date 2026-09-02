import Foundation
import CryptoKit

/// Disk cache for remote social images (post photos, avatars), keyed by **storage path** — not by
/// signed URL, whose expiry is unrelated to the bytes' validity. Lives in Caches (purgeable by
/// the system), pruned LRU past ~200 MB. Fetch-through: at most one network fetch per path per
/// process; concurrent requests for the same path coalesce.
actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private let directory: URL
    private let byteLimit: Int
    private var inflight: [String: Task<Data?, Never>] = [:]
    /// Directory enumeration is O(number of cached files). Doing it after every downloaded avatar
    /// made a 20-row page scan the same directory repeatedly; batch it while keeping overshoot small.
    private var writesSincePrune = 0

    init(byteLimit: Int = 200 * 1024 * 1024) {
        self.byteLimit = byteLimit
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("social-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Cached bytes for `path`, fetching (and storing) via `fetch` on a miss. nil = miss + fetch
    /// failed — the caller renders without the image (route/glyph media fallback).
    func data(for path: String, fetch: @escaping @Sendable () async -> Data?) async -> Data? {
        let file = fileURL(for: path)
        if let cached = await Self.readAndTouch(file) { return cached }
        if let running = inflight[path] { return await running.value }
        let task = Task<Data?, Never> { await fetch() }
        inflight[path] = task
        let fetched = await task.value
        inflight[path] = nil
        if let fetched {
            await Self.write(fetched, to: file)
            writesSincePrune += 1
            if writesSincePrune >= 12 || fetched.count >= byteLimit / 10 {
                writesSincePrune = 0
                await Self.prune(directory: directory, byteLimit: byteLimit)
            }
        }
        return fetched
    }

    private func fileURL(for path: String) -> URL {
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }

    /// Oldest-touched files go first once the cache exceeds the byte limit.
    nonisolated private static func readAndTouch(_ file: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let cached = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: file.path)
            return cached
        }.value
    }

    nonisolated private static func write(_ data: Data, to file: URL) async {
        await Task.detached(priority: .utility) {
            try? data.write(to: file, options: .atomic)
        }.value
    }

    nonisolated private static func prune(directory: URL, byteLimit: Int) async {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            var entries: [(url: URL, size: Int, touched: Date)] = files.compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0,
                        values.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > byteLimit else { return }
            entries.sort { $0.touched < $1.touched }
            for entry in entries {
                guard total > byteLimit else { break }
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }.value
    }
}
