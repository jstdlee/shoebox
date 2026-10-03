import Foundation
import ShoeboxCore

/// Build-time identifiers, read from each target's Info.plist (see project.yml).
enum AppEnvironment {
    static var appGroup: String { string("ShoeboxAppGroup") }
    static var keychainGroup: String { string("ShoeboxKeychainGroup") }
    static var refreshTaskID: String { string("ShoeboxRefreshTaskID") }

    /// The `BackgroundUploadURLBase` the upload extension is built with.
    static var uploadURLBase: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "BackgroundUploadURLBase") as? String).flatMap(URL.init(string:))
    }

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        // Unsigned Simulator builds (CI) have no App Group entitlement. Use the
        // app's own folder; the extension can't share it, which is fine there.
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shoebox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `-demo <scenario>` launch argument: sample data for screenshots, no PhotoKit or network.
    /// Or the "Show sample data" switch in Help (stored in UserDefaults).
    static var demoScenario: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demo") {
            return args.indices.contains(i + 1) ? args[i + 1] : "active"
        }
        return UserDefaults.standard.string(forKey: demoDefaultsKey)
    }

    static let demoDefaultsKey = "ShoeboxDemo"

    /// Sample data turned on by the user (not by a screenshot launch argument).
    static var demoFromUser: Bool {
        !ProcessInfo.processInfo.arguments.contains("-demo") && UserDefaults.standard.string(forKey: demoDefaultsKey) != nil
    }

    static var engineDirectory: URL { containerURL.appendingPathComponent("engine", isDirectory: true) }
    static var lockURL: URL { containerURL.appendingPathComponent("engine.lock") }

    private static func string(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("Missing \(key) in Info.plist")
        }
        return value
    }
}

/// Builds a BackupEngine wired to PhotoKit, the Keychain and the App Group.
/// Used by both the app and the upload extension.
enum EngineFactory {
    static func make() throws -> BackupEngine {
        let repository = SettingsRepository()
        let settings = repository.loadSettings()
        let credentials = repository.loadCredentials()
        let library = PhotoKitLibrarySource()
        let remote: SnapshotStore
        if let s3 = settings.s3, let credentials {
            remote = S3SnapshotStore(client: S3Client(config: s3, credentials: credentials, transport: URLSessionTransport()),
                                     layout: KeyLayout(prefix: s3.normalizedPrefix))
        } else {
            remote = UnconfiguredSnapshotStore()
        }
        return BackupEngine(settings: settings, credentials: credentials, library: library,
                            queue: PhotoKitJobQueue(library: library), remote: remote,
                            store: try FileStateStore(directory: AppEnvironment.engineDirectory),
                            lock: FileLock(url: AppEnvironment.lockURL),
                            uploadURLBase: AppEnvironment.uploadURLBase)
    }
}

/// Placeholder until storage is configured; the engine never reaches it
/// because it validates settings first.
final class UnconfiguredSnapshotStore: SnapshotStore {
    struct NotConfigured: Error {}
    func putManifest(_ manifest: Manifest, key: String) async throws { throw NotConfigured() }
    func listSnapshots() async throws -> [RemoteSnapshot] { throw NotConfigured() }
    func deleteSnapshot(_ id: SnapshotID, maxBatches: Int) async throws -> (done: Bool, batchesUsed: Int) { throw NotConfigured() }
}
