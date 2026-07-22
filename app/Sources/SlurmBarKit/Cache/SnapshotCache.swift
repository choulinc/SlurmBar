import Foundation

/// Last-known-good snapshot per cluster, on disk.
///
/// This is what makes the app useful on launch and while the VPN is down: the popover shows the
/// last successful snapshot immediately, clearly labelled as stale, instead of a spinner or an
/// empty window.
public struct SnapshotCache: Sendable {
    private let directory: URL

    // FileManager is not Sendable, so only the resolved directory is stored; the operations
    // used here (create/read/write/remove) are safe on FileManager.default from any thread.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? SnapshotCache.defaultDirectory(fileManager: fileManager)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("SlurmBar/snapshots", isDirectory: true)
    }

    private func url(for clusterID: UUID) -> URL {
        directory.appendingPathComponent("\(clusterID.uuidString).json")
    }

    public func load(clusterID: UUID) -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: url(for: clusterID)) else { return nil }
        return try? ProtocolDecoder.makeJSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    public func store(_ snapshot: Snapshot, clusterID: UUID, fetchedAt: Date = Date()) {
        let payload = CachedSnapshot(fetchedAt: fetchedAt, snapshot: snapshot)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: url(for: clusterID), options: .atomic)
        } catch {
            // A cache miss is a cosmetic problem; never let it surface as a refresh failure.
            NSLog("SlurmBar: could not cache snapshot: %@", String(describing: error))
        }
    }

    public func remove(clusterID: UUID) {
        try? FileManager.default.removeItem(at: url(for: clusterID))
    }
}

public struct CachedSnapshot: Codable, Hashable, Sendable {
    public let fetchedAt: Date
    public let snapshot: Snapshot

    public init(fetchedAt: Date, snapshot: Snapshot) {
        self.fetchedAt = fetchedAt
        self.snapshot = snapshot
    }
}
