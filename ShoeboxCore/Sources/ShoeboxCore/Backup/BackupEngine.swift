import Foundation

public enum EngineOutcome: Equatable, Sendable {
    /// Nothing left to do until the next backup is due.
    case completed
    /// Uploads are in flight or more jobs remain; call again later.
    case processing
    case failure(String)
}

/// One pass of the backup state machine. Called by the upload extension
/// whenever the system wakes it, and by the app (on open, "Back up now",
/// background refresh). Each pass does a bounded amount of work:
///
/// 1. Acknowledge finished upload jobs, recording successes and failures.
/// 2. If no snapshot is active and one is due, start a new one: freeze the
///    list of assets to back up.
/// 3. Create upload jobs (presigned PUTs) until the system job limit is full.
/// 4. When every job of the snapshot is done, upload manifest.json.
/// 5. Delete snapshots beyond "keep latest X".
public final class BackupEngine {
    public let settings: BackupSettings
    public let credentials: S3Credentials?
    let library: PhotoLibrarySource
    let queue: UploadJobQueue
    let remote: SnapshotStore
    let store: StateStore
    let clock: Clock
    let lock: FileLock?
    let layout: KeyLayout
    let presigner: S3Client?
    /// The extension's `BackgroundUploadURLBase`; uploads outside it would be
    /// rejected by the system, so refuse to start.
    let uploadURLBase: URL?

    public init(settings: BackupSettings, credentials: S3Credentials?, library: PhotoLibrarySource,
                queue: UploadJobQueue, remote: SnapshotStore, store: StateStore,
                clock: Clock = SystemClock(), lock: FileLock? = nil, timeZone: TimeZone = .current,
                uploadURLBase: URL? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.settings = settings
        self.credentials = credentials
        self.library = library
        self.queue = queue
        self.remote = remote
        self.store = store
        self.clock = clock
        self.lock = lock
        self.uploadURLBase = uploadURLBase
        self.layout = KeyLayout(prefix: settings.s3?.normalizedPrefix ?? "", timeZone: timeZone)
        if let s3 = settings.s3, let credentials {
            presigner = S3Client(config: s3, credentials: credentials, transport: transport, clock: clock)
        } else {
            presigner = nil
        }
    }

    /// Ask for a snapshot now, regardless of the schedule.
    public func requestBackupNow() throws {
        var state = try store.load()
        state.forceBackupRequested = true
        try store.save(state)
    }

    /// Mark retention to run on the next pass (e.g. after "keep latest" changed).
    public func requestRetention() throws {
        var state = try store.load()
        state.retentionPending = true
        try store.save(state)
    }

    public func currentState() throws -> EngineState {
        try store.load()
    }

    public func run(shouldStop: () -> Bool = { false }) async -> EngineOutcome {
        if let lock, !lock.tryLock() {
            // Another process is running a pass; ask to be called again.
            return .processing
        }
        defer { lock?.unlock() }

        var state: EngineState
        do {
            state = try store.load()
        } catch {
            return .failure("Cannot read state: \(error)")
        }
        state.lastRunAt = clock.now()

        var problems = settings.validate()
        if credentials?.isComplete != true { problems.append("Access keys are missing") }
        if let base = uploadURLBase, let s3 = settings.s3, !s3.isAllowed(byUploadURLBase: base) {
            problems.append("Endpoint is outside this build's upload URL base (\(base.absoluteString))")
        }
        guard problems.isEmpty, let presigner else {
            state.lastError = problems.joined(separator: "; ")
            try? store.save(state)
            return .completed
        }

        do {
            let outcome = try await pass(&state, presigner: presigner, shouldStop: shouldStop)
            if case .failure = outcome {} else { state.lastError = nil }
            try store.save(state)
            return outcome
        } catch UploadJobQueueError.limitExceeded {
            try? store.save(state)
            return .processing
        } catch {
            state.lastError = String(describing: error)
            try? store.save(state)
            return .failure(String(describing: error))
        }
    }

    // MARK: Pass

    private func pass(_ state: inout EngineState, presigner: S3Client, shouldStop: () -> Bool) async throws -> EngineOutcome {
        try acknowledgeFinishedJobs(&state)

        if state.active == nil {
            let due = settings.schedule.isDue(lastCompletedStart: state.lastCompleted?.startedAt, now: clock.now())
            if due || state.forceBackupRequested {
                try startSnapshot(&state)
            }
        }

        if state.active != nil {
            try reconcileLostJobs(&state)
            if !shouldStop() {
                try createJobs(&state, presigner: presigner, shouldStop: shouldStop)
            }
            if state.active?.isFinished == true {
                try await finishSnapshot(&state)
            }
        }

        if state.active == nil && state.retentionPending && !shouldStop() {
            try await applyRetention(&state)
        }

        if state.active != nil { return .processing }
        return state.retentionPending ? .processing : .completed
    }

    // MARK: 1. Acknowledge

    private func acknowledgeFinishedJobs(_ state: inout EngineState) throws {
        let finished = try queue.finishedJobs()
        guard !finished.isEmpty else { return }
        var uploadedKeys: [String] = []
        let classifier = FailureClassifier(maxAttempts: settings.maxAttemptsPerFile)

        if var active = state.active, let s3 = settings.s3 {
            for job in finished {
                guard let url = job.destination, let key = s3.key(fromObjectURL: url),
                      let flight = active.inFlight.removeValue(forKey: key) else {
                    continue // Not ours, or from an earlier snapshot: just acknowledge.
                }
                switch job.state {
                case .succeeded:
                    uploadedKeys.append(key)
                    active.uploadedCount += 1
                case .failed, .cancelled:
                    let attempts = flight.attempts + 1
                    switch classifier.decide(errorDomain: job.errorDomain, errorCode: job.errorCode, attempts: attempts) {
                    case .retry:
                        active.retries.append(PendingRetry(key: key, assetID: flight.assetID, resource: flight.resource, attempts: attempts))
                    case .giveUp(let reason):
                        active.failed.append(FailedFile(key: key, reason: reason))
                    }
                case .registered, .pending:
                    active.inFlight[key] = flight // Shouldn't be listed as finished; keep tracking.
                }
            }
            try store.appendUploaded(uploadedKeys, for: active.id)
            state.active = active
        }
        // Persist before acknowledging: if we die in between, the jobs show up
        // again and are ignored as unknown, which is harmless.
        try store.save(state)
        try queue.acknowledge(jobIDs: finished.map(\.id))
    }

    /// If the system has no jobs at all but we still think some are in flight,
    /// those were lost (e.g. crash between acknowledge and save, or the user
    /// toggled the extension). Queue them again.
    private func reconcileLostJobs(_ state: inout EngineState) throws {
        guard var active = state.active, !active.inFlight.isEmpty else { return }
        guard try queue.processingJobCount() == 0, try queue.finishedJobs().isEmpty else { return }
        for (key, flight) in active.inFlight.sorted(by: { $0.key < $1.key }) {
            active.retries.append(PendingRetry(key: key, assetID: flight.assetID, resource: flight.resource, attempts: flight.attempts))
        }
        active.inFlight.removeAll()
        state.active = active
    }

    // MARK: 2. Start

    private func startSnapshot(_ state: inout EngineState) throws {
        let now = clock.now()
        var id = SnapshotID(date: now)
        if let last = state.lastCompleted?.id, id <= last {
            // Two snapshots in the same second (or clock went back): stay unique and ordered.
            id = SnapshotID(date: last.date.addingTimeInterval(1))
        }
        let assetIDs = try library.allAssetIDs(policy: settings.resources)
        try store.savePlan(assetIDs, for: id)
        state.active = ActiveSnapshot(id: id, startedAt: now, totalAssets: assetIDs.count)
        state.forceBackupRequested = false
    }

    // MARK: 3. Create jobs

    private func createJobs(_ state: inout EngineState, presigner: S3Client, shouldStop: () -> Bool) throws {
        guard var active = state.active else { return }
        let outstanding = try queue.processingJobCount() + queue.finishedJobs().count
        var capacity = queue.jobLimit - outstanding
        guard capacity > 0 else { return }

        var batch: [NewUploadJob] = []
        var batchFlights: [(String, InFlightJob)] = []

        func add(key: String, assetID: String, resource: ResourceInfo, attempts: Int) {
            let destination = presigner.presignedPut(key: key, contentType: ContentType.forFilename(resource.originalFilename),
                                                     expires: settings.presignSeconds)
            batch.append(NewUploadJob(assetID: assetID, resource: resource, destination: destination))
            batchFlights.append((key, InFlightJob(assetID: assetID, resource: resource, attempts: attempts)))
            capacity -= 1
        }

        // Retries first.
        var retriesTaken = 0
        for retry in active.retries {
            guard capacity > 0, !shouldStop() else { break }
            retriesTaken += 1
            guard library.asset(id: retry.assetID) != nil else {
                active.failed.append(FailedFile(key: retry.key, reason: "Asset was deleted"))
                continue
            }
            add(key: retry.key, assetID: retry.assetID, resource: retry.resource, attempts: retry.attempts)
        }

        // Then walk the plan.
        var cursor = active.cursor
        if capacity > 0 && !active.planExhausted {
            let plan = try store.loadPlan(for: active.id)
            while capacity > 0, cursor.asset < plan.count, !shouldStop() {
                let assetID = plan[cursor.asset]
                guard let asset = library.asset(id: assetID) else {
                    active.skippedAssets += 1
                    cursor = PlanCursor(asset: cursor.asset + 1, resource: 0)
                    continue
                }
                let resources = settings.resources.select(library.resources(assetID: assetID))
                let keys = layout.objectKeys(snapshot: active.id, asset: asset, resources: resources)
                while capacity > 0, cursor.resource < resources.count {
                    add(key: keys[cursor.resource], assetID: assetID, resource: resources[cursor.resource], attempts: 0)
                    cursor.resource += 1
                }
                if cursor.resource >= resources.count {
                    cursor = PlanCursor(asset: cursor.asset + 1, resource: 0)
                }
            }
        }

        if !batch.isEmpty {
            // Atomic: on limitExceeded nothing was created and `state` is left
            // untouched, so the same work is redone on the next pass.
            try queue.create(batch)
        }
        active.retries.removeFirst(retriesTaken)
        active.cursor = cursor
        for (key, flight) in batchFlights { active.inFlight[key] = flight }
        state.active = active
    }

    // MARK: 4. Finish

    private func finishSnapshot(_ state: inout EngineState) async throws {
        guard let active = state.active else { return }
        let uploaded = try store.loadUploaded(for: active.id)
        var seen = Set<String>()
        let files = uploaded.filter { seen.insert($0).inserted }
        let now = clock.now()
        let manifest = Manifest(snapshotID: active.id, startedAt: active.startedAt, completedAt: now,
                                assetCount: active.totalAssets, skippedAssets: active.skippedAssets,
                                files: files, failed: active.failed)
        try await remote.putManifest(manifest, key: layout.manifestKey(active.id))

        state.record(SnapshotSummary(id: active.id, startedAt: active.startedAt, completedAt: now,
                                     assetCount: active.totalAssets, uploadedFiles: files.count,
                                     failedFiles: active.failed.count, skippedAssets: active.skippedAssets))
        state.active = nil
        state.retentionPending = true
        try store.save(state)
        try? store.removeSnapshotFiles(for: active.id)
    }

    // MARK: 5. Retention

    private func applyRetention(_ state: inout EngineState) async throws {
        let snapshots = try await remote.listSnapshots()
        let doomed = settings.retention.snapshotsToDelete(snapshots, active: state.active?.id)
        var budget = settings.maxDeleteBatchesPerRun
        for id in doomed {
            guard budget > 0 else { return }
            let (done, used) = try await remote.deleteSnapshot(id, maxBatches: budget)
            budget -= used
            if !done { return }
        }
        state.retentionPending = false
    }
}
