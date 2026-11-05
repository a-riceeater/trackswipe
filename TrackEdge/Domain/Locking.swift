import Foundation

extension NSLock {
    /// Runs `body` while holding the lock. (`NSLocking.withLock` requires macOS 14; we target 13.)
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
