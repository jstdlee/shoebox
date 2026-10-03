import Foundation

/// Injectable time source so scheduling and signing are testable.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ date: Date) { current = date }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

enum UTCFormat {
    /// `20260929T020000Z` — used for SigV4 and snapshot ids.
    static func basic(_ date: Date) -> String {
        formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
    }

    static func parseBasic(_ string: String) -> Date? {
        formatter("yyyyMMdd'T'HHmmss'Z'").date(from: string)
    }

    /// `20260929` — SigV4 credential scope date.
    static func day(_ date: Date) -> String {
        formatter("yyyyMMdd").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
}
