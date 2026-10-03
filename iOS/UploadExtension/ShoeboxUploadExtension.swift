import ExtensionFoundation
import Foundation
import Photos
import ShoeboxCore

/// Entry point the system calls when it's a good time to upload (network,
/// power, device idle). Each call runs one bounded engine pass.
///
/// iOS 26.1 uses `PHBackgroundResourceUploadExtension` (synchronous). On iOS 27
/// Apple adds the async `PHBackgroundResourceUploadJobExtension`, and 26.1's
/// protocol becomes deprecated but still works. When the minimum target moves to 27,
/// switch the protocol and replace `process()` with:
///
///     func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
///         await Self.map(engine.run(shouldStop: { stop.isSet }))
///     }
@main
final class ShoeboxUploadExtension: PHBackgroundResourceUploadExtension {
    private let stop = StopFlag()

    required init() {}

    func process() -> PHBackgroundResourceUploadProcessingResult {
        stop.reset()
        let engine: BackupEngine
        do {
            engine = try EngineFactory.make()
        } catch {
            return .failure
        }
        let stop = self.stop
        let outcome = runBlocking { await engine.run(shouldStop: { stop.isSet }) }
        return Self.map(outcome)
    }

    func notifyTermination() {
        stop.set()
    }

    static func map(_ outcome: EngineOutcome) -> PHBackgroundResourceUploadProcessingResult {
        switch outcome {
        case .completed: return .completed
        case .processing: return .processing
        case .failure: return .failure
        }
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }
}
