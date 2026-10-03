import Foundation
import Photos
import ShoeboxCore

/// UI state: an editable copy of the settings plus the engine's status.
@MainActor
final class AppModel: ObservableObject {
    // Storage form
    @Published var endpoint = ""
    @Published var region = "auto"
    @Published var bucket = ""
    @Published var prefix = ""
    @Published var usePathStyle = true
    @Published var accessKeyID = ""
    @Published var secretAccessKey = ""

    // Schedule & content
    @Published var intervalDays = 7
    @Published var keepLatest = 3
    @Published var includeVideos = true
    @Published var includeLivePhotoVideos = true
    @Published var includeEdits = true

    // Status
    @Published private(set) var state = EngineState()
    @Published private(set) var photoAccess: PHAuthorizationStatus = .notDetermined
    @Published private(set) var backgroundEnabled = false
    @Published var message: String?
    @Published private(set) var busy = false

    private let repository = SettingsRepository()

    init() {
        if let scenario = AppEnvironment.demoScenario {
            loadDemo(scenario)
        } else {
            load()
        }
    }

    var isDemo: Bool { AppEnvironment.demoScenario != nil }

    var uploadURLBase: String {
        if isDemo { return endpoint }
        return AppEnvironment.uploadURLBase?.absoluteString ?? "(not set)"
    }

    var nextDue: Date? {
        BackupSchedule(intervalDays: intervalDays).nextDue(lastCompletedStart: state.lastCompleted?.startedAt)
    }

    // MARK: Lifecycle

    func onForeground() async {
        guard !isDemo else { return }
        photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        backgroundEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
        refreshState()
        if photoAccess == .authorized && backgroundEnabled {
            _ = await Self.runEngineOnce()
            refreshState()
        }
    }

    func refreshState() {
        guard !isDemo else { return }
        if let engine = try? EngineFactory.make(), let state = try? engine.currentState() {
            self.state = state
        }
    }

    // MARK: Settings

    func load() {
        let settings = repository.loadSettings()
        if let s3 = settings.s3 {
            endpoint = s3.endpoint.absoluteString
            region = s3.region
            bucket = s3.bucket
            prefix = s3.prefix
            usePathStyle = s3.usePathStyle
        } else if let base = AppEnvironment.uploadURLBase {
            endpoint = base.absoluteString
        }
        intervalDays = settings.intervalDays
        keepLatest = settings.keepLatest
        includeVideos = settings.resources.includeVideos
        includeLivePhotoVideos = settings.resources.includeLivePhotoVideos
        includeEdits = settings.resources.includeEdits
        if let credentials = repository.loadCredentials() {
            accessKeyID = credentials.accessKeyID
            secretAccessKey = credentials.secretAccessKey
        }
    }

    /// Builds settings from the form; returns validation problems.
    func formSettings() -> (BackupSettings, [String]) {
        var settings = repository.loadSettings()
        var problems: [String] = []
        if let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), url.host != nil {
            let s3 = S3Config(endpoint: url, region: region.trimmingCharacters(in: .whitespaces),
                              bucket: bucket.trimmingCharacters(in: .whitespaces),
                              prefix: prefix, usePathStyle: usePathStyle)
            settings.s3 = s3
            if let base = AppEnvironment.uploadURLBase, !s3.isAllowed(byUploadURLBase: base) {
                problems.append("This build only uploads under \(base.absoluteString). Change SHOEBOX_UPLOAD_URL_BASE in project.yml to use another endpoint.")
            }
        } else {
            problems.append("Endpoint is not a valid URL")
        }
        settings.intervalDays = intervalDays
        settings.keepLatest = keepLatest
        settings.resources = ResourcePolicy(includeVideos: includeVideos, includeLivePhotoVideos: includeLivePhotoVideos,
                                            includeEdits: includeEdits)
        problems += settings.validate().filter { !problems.contains($0) }
        if accessKeyID.isEmpty || secretAccessKey.isEmpty { problems.append("Access key ID and secret are required") }
        return (settings, problems)
    }

    func save() {
        let (settings, problems) = formSettings()
        guard problems.isEmpty else {
            message = problems.joined(separator: "\n")
            return
        }
        do {
            let previous = repository.loadSettings()
            try repository.saveSettings(settings)
            try repository.saveCredentials(S3Credentials(accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces),
                                                         secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespaces)))
            if previous.keepLatest != settings.keepLatest {
                try EngineFactory.make().requestRetention()
            }
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    /// Lists the bucket and writes + deletes a small probe object, so bad keys
    /// or permissions show up now instead of in the background.
    func testConnection() async {
        let (settings, problems) = formSettings()
        guard problems.isEmpty, let s3 = settings.s3 else {
            message = problems.joined(separator: "\n")
            return
        }
        busy = true
        defer { busy = false }
        let client = S3Client(config: s3, credentials: S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey),
                              transport: URLSessionTransport())
        let probe = KeyLayout(prefix: s3.normalizedPrefix).snapshotsRoot + ".shoebox-probe"
        do {
            _ = try await client.listObjects(prefix: KeyLayout(prefix: s3.normalizedPrefix).snapshotsRoot, maxKeys: 1)
            try await client.putObject(key: probe, body: Data("ok".utf8), contentType: "text/plain")
            _ = try await client.deleteObjects(keys: [probe])
            message = "Connection OK: list, write and delete work"
        } catch {
            message = "Connection failed: \(error)"
        }
    }

    /// Photo access + turn on the background upload extension.
    func enableBackgroundBackup() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccess = status
        guard status == .authorized else {
            message = "Shoebox needs Full Access to photos (Settings → Privacy → Photos)."
            return
        }
        do {
            try PHPhotoLibrary.shared().setUploadJobExtensionEnabled(true)
            backgroundEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
            message = backgroundEnabled ? "Background backup is on" : "iOS did not enable background backup"
        } catch {
            message = "Could not enable background backup: \(error.localizedDescription)"
        }
    }

    func disableBackgroundBackup() {
        do {
            try PHPhotoLibrary.shared().setUploadJobExtensionEnabled(false)
            backgroundEnabled = false
        } catch {
            message = error.localizedDescription
        }
    }

    func backUpNow() async {
        busy = true
        defer { busy = false }
        do {
            try EngineFactory.make().requestBackupNow()
        } catch {
            message = "\(error)"
            return
        }
        let outcome = await Self.runEngineOnce()
        refreshState()
        switch outcome {
        case .processing: message = "Backup started. Uploads continue in the background."
        case .completed: message = state.lastError ?? "Backup complete"
        case .failure(let reason): message = "Backup problem: \(reason)"
        }
    }

    /// One engine pass off the main thread (PhotoKit calls block).
    nonisolated static func runEngineOnce() async -> EngineOutcome {
        await Task.detached(priority: .utility) {
            guard let engine = try? EngineFactory.make() else { return EngineOutcome.failure("Cannot open state") }
            return await engine.run()
        }.value
    }

    // MARK: Demo data (screenshots)

    private func loadDemo(_ scenario: String) {
        endpoint = "https://4f2c9e7a1b.r2.cloudflarestorage.com"
        region = "auto"
        bucket = "family-photos"
        prefix = "iphone"
        accessKeyID = "a3f9c2e81d7b4c06"
        secretAccessKey = "demo-secret-not-real"
        intervalDays = 7
        keepLatest = 3
        photoAccess = .authorized
        backgroundEnabled = true

        // Fixed clock so gallery screenshots don't change between CI runs.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        var demo = EngineState()
        demo.history = (1...3).map { week in
            let start = now.addingTimeInterval(-Double(week) * 7 * day)
            return SnapshotSummary(id: SnapshotID(date: start), startedAt: start,
                                   completedAt: start.addingTimeInterval(5 * 3600),
                                   assetCount: 8_412 - week * 37, uploadedFiles: 11_903 - week * 52,
                                   failedFiles: week == 2 ? 1 : 0, skippedAssets: week == 3 ? 2 : 0)
        }
        demo.lastCompleted = demo.history.first
        if scenario == "active" {
            let start = now.addingTimeInterval(-2 * 3600)
            var active = ActiveSnapshot(id: SnapshotID(date: start), startedAt: start, totalAssets: 8_431)
            active.cursor = PlanCursor(asset: 5_270, resource: 0)
            active.uploadedCount = 7_388
            active.inFlight = Dictionary(uniqueKeysWithValues: (0..<40).map {
                ("k\($0)", InFlightJob(assetID: "a\($0)", resource: ResourceInfo(kind: .photo, originalFilename: "x.heic", index: 0), attempts: 0))
            })
            demo.active = active
        }
        state = demo
    }
}
