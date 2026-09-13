import Foundation

/// Persistence seam for offline meetings. SQLite lives in user space only.
public protocol OfflineMeetingStoring: Sendable {
    func upsert(_ record: OfflineMeetingRecord) throws
    func meeting(id: UUID) throws -> OfflineMeetingRecord?
    func allMeetings() throws -> [OfflineMeetingRecord]
    func recordingMeeting() throws -> OfflineMeetingRecord?
    func meetingsEligibleForPurge(at now: Date) throws -> [OfflineMeetingRecord]
    func markArtifactsPurged(id: UUID, at date: Date) throws
    func hasRegisteredArtifactHash(_ sha256: String, kind: MeetingArtifactKind, excluding meetingID: UUID) throws -> Bool
    func applyAuditLifecycle(_ record: OfflineMeetingRecord) throws
}

/// Deterministic in-memory adapter used by coordinator tests.
public final class InMemoryOfflineMeetingStore: OfflineMeetingStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var records: [UUID: OfflineMeetingRecord] = [:]

    public init() {}

    public func upsert(_ record: OfflineMeetingRecord) throws {
        try withLock {
            try Self.rejectDuplicateHashes(record, existing: Array(records.values))
            records[record.id] = record
        }
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

    public func hasRegisteredArtifactHash(
        _ sha256: String,
        kind: MeetingArtifactKind,
        excluding meetingID: UUID
    ) throws -> Bool {
        withLock {
            records.values.contains { other in
                other.id != meetingID
                    && other.auditStatus != .abandoned
                    && other.sha256(for: kind) == sha256
            }
        }
    }

    public func applyAuditLifecycle(_ record: OfflineMeetingRecord) throws {
        try withLock {
            guard records[record.id] != nil else {
                throw OfflineMeetingError.meetingNotFound
            }
            records[record.id] = record
        }
    }

    private static func rejectDuplicateHashes(
        _ record: OfflineMeetingRecord,
        existing: [OfflineMeetingRecord]
    ) throws {
        for kind in [MeetingArtifactKind.receipt, .environmentPhoto] {
            guard let sha = record.sha256(for: kind) else { continue }
            let collision = existing.contains { other in
                other.id != record.id
                    && other.auditStatus != .abandoned
                    && other.sha256(for: kind) == sha
            }
            if collision {
                throw OfflineMeetingError.duplicateArtifact(kind)
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
