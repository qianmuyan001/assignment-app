import Darwin
import Foundation


enum DatabaseMigrationLock {
    private static let processLock = NSLock()
    private static let timeoutNanoseconds: UInt64 = 30_000_000_000
    private static let retryMicroseconds: useconds_t = 50_000

    static func withExclusiveLock<T>(for databaseURL: URL, _ body: () throws -> T) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        guard acquireProcessLock(until: deadline) else {
            throw DatabaseMigrationError(
                "Timed out after 30 seconds waiting for the in-process migration lock."
            )
        }
        defer { processLock.unlock() }

        return try autoreleasepool {
            let lockURL = databaseURL.appendingPathExtension("migration.lock")
            let descriptor = Darwin.open(
                lockURL.path,
                O_CREAT | O_RDWR | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw DatabaseMigrationError(
                    "Could not open migration lock \(lockURL.lastPathComponent): \(lastError)."
                )
            }
            defer { Darwin.close(descriptor) }
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                    throw DatabaseMigrationError("Could not acquire migration lock: \(lastError).")
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw DatabaseMigrationError(
                        "Timed out after 30 seconds waiting for migration lock "
                            + "\(lockURL.lastPathComponent)."
                    )
                }
                usleep(retryMicroseconds)
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private static func acquireProcessLock(until deadline: UInt64) -> Bool {
        while !processLock.try() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            usleep(retryMicroseconds)
        }
        return true
    }

    private static var lastError: String {
        String(cString: strerror(errno))
    }
}
