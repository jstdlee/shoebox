import Foundation
import Photos
import ShoeboxCore

/// UI state: an editable copy of the settings plus the engine's status.
/// Settings save as you change them; problems show inline, never in alerts.
@MainActor
final class AppModel: ObservableObject {
    // Storage form
    @Published var endpoint = "" { didSet { edited() } }
    @Published var region = "auto" { didSet { edited() } }
    @Published var bucket = "" { didSet { edited() } }
    @Published var prefix = "" { didSet { edited() } }
    @Published var usePathStyle = true { didSet { edited() } }
    @Published var accessKeyID = "" { didSet { edited() } }
    @Published var secretAccessKey = "" { didSet { edited() } }

    // Schedule & content
    @Published var intervalDays = 7 { didSet { edited() } }
    @Published var keepLatest = 3 { didSet { edited() } }
    @Published var includeVideos = true { didSet { edited() } }
    @Published var includeLivePhotoVideos = true { didSet { edited() } }
    @Published var includeEdits = true { didSet { edited() } }

    // Status
    @Published private(set) var state = EngineState()
    @Published private(set) var photoAccess: PHAuthorizationStatus = .notDetermined
    @Published private(set) var backgroundEnabled = false
    @Published private(set) var isConfigured = false
    /// Validation problems of the form; shown only after the user edits.
    @Published private(set) var formProblems: [String] = []
    @Published private(set) var connection: ConnectionCheck = .idle
    @Published private(set) var backgroundProblem: String?
    @Published private(set) var busy = false
    /// Changes when a haptic should play.
    @Published private(set) var haptic = HapticEvent(kind: .success)

    enum ConnectionCheck: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    struct HapticEvent: Equatable {
        enum Kind { case success, warning }
        var kind: Kind
        var id = UUID()
    }

    private let repository = SettingsRepository()
    private var loading = false
    private var userEdited = false
    private var saveTask: Task<Void, Never>?

    init() {
        loading = true
        if let scenario = AppEnvironment.demoScenario {
            loadDemo(scenario)
        } else {
            load()
        }
        loading = false
    }

    var isDemo: Bool { AppEnvironment.demoScenario != nil }

    var uploadURLBase: String {
        if isDemo { return endpoint }
        return AppEnvironment.uploadURLBase?.absoluteString ?? "—"
    }

    var nextDue: Date? {
        BackupSchedule(intervalDays: intervalDays).nextDue(lastCompletedStart: state.lastCompleted?.startedAt)
    }

    var visibleProblems: [String] { userEdited ? formProblems : [] }

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
        let credentials = repository.loadCredentials()
        if let credentials {
            accessKeyID = credentials.accessKeyID
            secretAccessKey = credentials.secretAccessKey
        }
        isConfigured = settings.s3 != nil && credentials?.isComplete == true
        formProblems = formSettings().1
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
            if let base = AppEnvironment.uploadURLBase, !isDemo, !s3.isAllowed(byUploadURLBase: base) {
                problems.append(String(localized: "This build uploads only under \(base.absoluteString)."))
            }
        } else {
            settings.s3 = nil
            problems.append(String(localized: "Endpoint is not a valid URL."))
        }
        settings.intervalDays = intervalDays
        settings.keepLatest = keepLatest
        settings.resources = ResourcePolicy(includeVideos: includeVideos, includeLivePhotoVideos: includeLivePhotoVideos,
                                            includeEdits: includeEdits)
        if settings.s3 != nil {
            problems += settings.validate().filter { !problems.contains($0) }
        }
        if accessKeyID.isEmpty || secretAccessKey.isEmpty {
            problems.append(String(localized: "Access key and secret are required."))
        }
        return (settings, problems)
    }

    private func edited() {
        guard !loading else { return }
        userEdited = true
        connection = .idle
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves when the form is valid. Invalid input stays on screen with the
    /// problem under it; the last valid settings stay in effect.
    func save() {
        let (settings, problems) = formSettings()
        formProblems = problems
        guard problems.isEmpty, !isDemo else { return }
        do {
            let previous = repository.loadSettings()
            try repository.saveSettings(settings)
            try repository.saveCredentials(S3Credentials(accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces),
                                                         secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespaces)))
            isConfigured = true
            if previous.keepLatest != settings.keepLatest {
                try EngineFactory.make().requestRetention()
            }
        } catch {
            formProblems = [String(localized: "Could not save: \(error.localizedDescription)")]
        }
    }

    // MARK: Actions

    /// Lists the bucket, writes and deletes a small probe object, so bad keys
    /// or permissions show up now instead of in the background.
    func testConnection() async {
        userEdited = true
        let (settings, problems) = formSettings()
        formProblems = problems
        guard problems.isEmpty, let s3 = settings.s3 else { return }
        if isDemo {
            connection = .ok
            return
        }
        connection = .checking
        let client = S3Client(config: s3, credentials: S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey),
                              transport: URLSessionTransport())
        let root = KeyLayout(prefix: s3.normalizedPrefix).snapshotsRoot
        do {
            _ = try await client.listObjects(prefix: root, maxKeys: 1)
            try await client.putObject(key: root + ".shoebox-probe", body: Data("ok".utf8), contentType: "text/plain")
            _ = try await client.deleteObjects(keys: [root + ".shoebox-probe"])
            connection = .ok
            haptic = HapticEvent(kind: .success)
        } catch {
            connection = .failed(String(describing: error))
            haptic = HapticEvent(kind: .warning)
        }
    }

    /// Photo access + the background upload extension.
    func setBackgroundBackup(_ on: Bool) async {
        backgroundProblem = nil
        guard !isDemo else {
            backgroundEnabled = on
            return
        }
        if on {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            photoAccess = status
            guard status == .authorized else {
                backgroundProblem = String(localized: "Shoebox needs Full Access to photos. Change it in Settings › Privacy › Photos.")
                haptic = HapticEvent(kind: .warning)
                return
            }
        }
        do {
            try PHPhotoLibrary.shared().setUploadJobExtensionEnabled(on)
        } catch {
            backgroundProblem = error.localizedDescription
            haptic = HapticEvent(kind: .warning)
        }
        backgroundEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
    }

    func backUpNow() async {
        guard !isDemo else { return }
        busy = true
        defer { busy = false }
        do {
            try EngineFactory.make().requestBackupNow()
        } catch {
            haptic = HapticEvent(kind: .warning)
            return
        }
        let outcome = await Self.runEngineOnce()
        refreshState()
        switch outcome {
        case .processing, .completed:
            haptic = HapticEvent(kind: state.lastError == nil ? .success : .warning)
        case .failure:
            haptic = HapticEvent(kind: .warning)
        }
    }

    /// One engine pass off the main thread (PhotoKit calls block).
    nonisolated static func runEngineOnce() async -> EngineOutcome {
        await Task.detached(priority: .utility) {
            guard let engine = try? EngineFactory.make() else { return EngineOutcome.failure("Cannot open state") }
            return await engine.run()
        }.value
    }

    // MARK: Demo data (screenshots and the "Show sample data" switch)

    /// Shows sample data, or goes back to the real settings and state.
    func setDemo(_ on: Bool) {
        UserDefaults.standard.set(on ? "active" : nil, forKey: AppEnvironment.demoDefaultsKey)
        saveTask?.cancel()
        loading = true
        if on {
            loadDemo("active")
        } else {
            // Clear the sample values first: load() only fills what is saved.
            endpoint = ""; region = "auto"; bucket = ""; prefix = ""; usePathStyle = true
            accessKeyID = ""; secretAccessKey = ""
            state = EngineState()
            connection = .idle
            formProblems = []
            userEdited = false
            load()
        }
        loading = false
        if !on {
            Task { await onForeground() }
        }
    }

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
        isConfigured = true

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
        if scenario == "setup" {
            isConfigured = false
            backgroundEnabled = false
            demo = EngineState()
        }
        state = demo
    }
}
