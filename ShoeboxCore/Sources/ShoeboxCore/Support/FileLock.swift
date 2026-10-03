import Foundation
import Darwin

/// Advisory `flock` on a file in the shared App Group container, so the app
/// and the upload extension never run the engine at the same time.
public final class FileLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    deinit { unlock() }

    /// Non-blocking. Returns false if another process (or another FileLock
    /// instance) holds the lock.
    public func tryLock() -> Bool {
        if fd >= 0 { return true }
        let handle = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return false }
        if flock(handle, LOCK_EX | LOCK_NB) != 0 {
            close(handle)
            return false
        }
        fd = handle
        return true
    }

    public func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
