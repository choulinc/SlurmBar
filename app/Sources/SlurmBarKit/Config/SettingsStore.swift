import Foundation

/// Persists ``AppSettings`` as JSON in Application Support.
///
/// A plain JSON file rather than `UserDefaults` so the configuration is inspectable, diffable
/// and easy to hand-edit or version — this is developer-facing software.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: AppSettings

    private let fileURL: URL
    private let fileManager: FileManager

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SlurmBar", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL ?? SettingsStore.defaultFileURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.settings = SettingsStore.load(from: self.fileURL) ?? .default
    }

    // MARK: - Mutation

    public func update(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        save()
    }

    public func addCluster(_ profile: ClusterProfile) {
        update { settings in
            settings.clusters.append(profile)
            if settings.selectedClusterID == nil {
                settings.selectedClusterID = profile.id
            }
        }
    }

    public func updateCluster(_ profile: ClusterProfile) {
        update { settings in
            guard let index = settings.clusters.firstIndex(where: { $0.id == profile.id }) else { return }
            settings.clusters[index] = profile
        }
    }

    public func removeCluster(id: UUID) {
        update { settings in
            settings.clusters.removeAll { $0.id == id }
            if settings.selectedClusterID == id {
                settings.selectedClusterID = settings.clusters.first?.id
            }
        }
    }

    public func selectCluster(id: UUID) {
        update { $0.selectedClusterID = id }
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Never destroy a settings file we cannot read: keep a copy so the user can recover
            // hand-edited configuration instead of silently starting from scratch.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? data.write(to: backup, options: .atomic)
            NSLog("SlurmBar: settings could not be read (%@); previous file kept at %@",
                  String(describing: error), backup.path)
            return nil
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SlurmBar: could not save settings: %@", String(describing: error))
        }
    }

    public var settingsFileURL: URL { fileURL }
}
