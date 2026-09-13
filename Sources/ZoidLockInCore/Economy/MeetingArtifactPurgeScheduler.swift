import Foundation

public struct MeetingPurgeReport: Sendable, Equatable {
    public var purgedMeetingIDs: [UUID]
    public var deletedFileCount: Int

    public init(purgedMeetingIDs: [UUID] = [], deletedFileCount: Int = 0) {
        self.purgedMeetingIDs = purgedMeetingIDs
        self.deletedFileCount = deletedFileCount
    }
}

/// Deletes raw photo/receipt/notes binaries older than 30 days. SQLite stays.
public final class MeetingArtifactPurgeScheduler: @unchecked Sendable {
    public let store: any OfflineMeetingStoring
    public let artifacts: MeetingArtifactStore
    public let wallClock: any WallClockProviding

    public init(
        store: any OfflineMeetingStoring,
        artifacts: MeetingArtifactStore,
        wallClock: any WallClockProviding = SystemWallClock()
    ) {
        self.store = store
        self.artifacts = artifacts
        self.wallClock = wallClock
    }

    @discardableResult
    public func purgeExpired(now: Date? = nil) throws -> MeetingPurgeReport {
        let instant = now ?? wallClock.now()
        let due = try store.meetingsEligibleForPurge(at: instant)
        var ids: [UUID] = []
        var deleted = 0
        for record in due {
            deleted += try artifacts.deleteBinaries(for: record)
            try store.markArtifactsPurged(id: record.id, at: instant)
            ids.append(record.id)
        }
        return MeetingPurgeReport(purgedMeetingIDs: ids, deletedFileCount: deleted)
    }
}
