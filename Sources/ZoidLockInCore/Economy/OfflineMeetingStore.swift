import Foundation

/// Persistence seam for offline meetings. SQLite lives in user space only.
public protocol OfflineMeetingStoring: Sendable {
    func upsert(_ record: OfflineMeetingRecord) throws
    func meeting(id: UUID) throws -> OfflineMeetingRecord?
    func allMeetings() throws -> [OfflineMeetingRecord]
    func recordingMeeting() throws -> OfflineMeetingRecord?
    func meetingsEligibleForPurge(at now: Date) throws -> [OfflineMeetingRecord]
    func markArtifactsPurged(id: UUID, at date: Date) throws
}

/// Deterministic in-memory adapter used by coordinator tests.
public final class InMemoryOfflineMeetingStore: OfflineMeetingStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var records: [UUID: OfflineMeetingRecord] = [:]

    public init() {}

    public func upsert(_ record: OfflineMeetingRecord) throws {
        withLock { records[record.id] = record }
    }

    public func meeting(id: UUID) throws -> OfflineMeetingRecord? {
        withLock { records[id] }
    }

    public func allMeetings() throws -> [OfflineMeetingRecord] {
        withLock {
            records.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func recordingMeeting() throws -> OfflineMeetingRecord? {
        try allMeetings().first(where: \.isRecording)
    }

    public func meetingsEligibleForPurge(at now: Date) throws -> [OfflineMeetingRecord] {
        try allMeetings().filter { record in
            guard record.artifactsPurgedAt == nil,
                  let purgeDate = record.artifactsPurgeDate,
                  purgeDate <= now
            else {
                return false
            }
            return record.notesLocalPath != nil
                || record.receiptLocalPath != nil
                || record.photoLocalPath != nil
        }
    }

    public func markArtifactsPurged(id: UUID, at date: Date) throws {
        withLock {
            guard var record = records[id] else { return }
            record.notesLocalPath = nil
            record.receiptLocalPath = nil
            record.photoLocalPath = nil
            record.artifactsPurgedAt = date
            records[id] = record
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
