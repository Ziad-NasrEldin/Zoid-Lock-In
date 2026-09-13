import Foundation

/// Punch-in / punch-out coordinator with a strict triple-artifact submission gate.
public final class OfflineSessionCoordinator: @unchecked Sendable {
    public let store: any OfflineMeetingStoring
    public let artifacts: MeetingArtifactStore
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let bootSessionUUID: String

    private let photoValidator: MeetingPhotoValidator
    private let lock = NSLock()
    private var active: OfflineMeetingRecord?
    private var lastError: String?

    public init(
        store: any OfflineMeetingStoring,
        artifacts: MeetingArtifactStore,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeZone: TimeZone = .current,
        bootSessionUUID: String = BootSession.currentUUID()
    ) {
        self.store = store
        self.artifacts = artifacts
        self.clock = clock
        self.wallClock = wallClock
        self.bootSessionUUID = bootSessionUUID
        self.photoValidator = MeetingPhotoValidator(timeZone: timeZone)
        self.active = try? store.recordingMeeting()
    }

    public var lastErrorMessage: String? {
        withLock { lastError }
    }

    public var activeMeeting: OfflineMeetingRecord? {
        withLock { active }
    }

    @discardableResult
    public func punchIn() throws -> OfflineMeetingRecord {
        try withLock {
            if let active, active.isRecording {
                lastError = OfflineMeetingError.alreadyRecording.localizedDescription
                throw OfflineMeetingError.alreadyRecording
            }
            let record = OfflineMeetingRecord(
                punchInUTC: wallClock.now(),
                punchInMonotonic: clock.nowSeconds(),
                bootSessionUUID: bootSessionUUID,
                createdAt: wallClock.now()
            )
            try store.upsert(record)
            active = record
            lastError = nil
            return record
        }
    }

    @discardableResult
    public func punchOut() throws -> OfflineMeetingRecord {
        try withLock {
            guard var record = active, record.isRecording else {
                lastError = OfflineMeetingError.notRecording.localizedDescription
                throw OfflineMeetingError.notRecording
            }
            guard record.bootSessionUUID == bootSessionUUID else {
                lastError = OfflineMeetingError.bootSessionChanged.localizedDescription
                throw OfflineMeetingError.bootSessionChanged
            }
            let punched = clock.nowSeconds()
            let duration = max(0, punched - record.punchInMonotonic)
            if duration + 0.000_1 < OfflineMeetingPolicy.minimumDuration {
                lastError = OfflineMeetingError.durationTooShort(duration).localizedDescription
                throw OfflineMeetingError.durationTooShort(duration)
            }
            if duration - 0.000_1 > OfflineMeetingPolicy.maximumDuration {
                lastError = OfflineMeetingError.durationTooLong(duration).localizedDescription
                throw OfflineMeetingError.durationTooLong(duration)
            }
            record.punchOutMonotonic = punched
            record.punchOutUTC = wallClock.now()
            record.durationSeconds = duration
            try store.upsert(record)
            active = record
            lastError = nil
            return record
        }
    }

    @discardableResult
    public func attach(kind: MeetingArtifactKind, from url: URL) throws -> StoredMeetingArtifact {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OfflineMeetingError.storageFailed(error.localizedDescription)
        }
        return try attach(kind: kind, data: data, fileExtension: url.pathExtension)
    }

    @discardableResult
    public func attach(
        kind: MeetingArtifactKind,
        data: Data,
        fileExtension: String
    ) throws -> StoredMeetingArtifact {
        try withLock {
            guard var record = active else {
                lastError = OfflineMeetingError.noActiveMeeting.localizedDescription
                throw OfflineMeetingError.noActiveMeeting
            }
            guard !record.isSubmitted else {
                lastError = OfflineMeetingError.alreadySubmitted.localizedDescription
                throw OfflineMeetingError.alreadySubmitted
            }
            if kind == .environmentPhoto, let punchOut = record.punchOutUTC {
                do {
                    _ = try photoValidator.validate(
                        imageData: data,
                        punchIn: record.punchInUTC,
                        punchOut: punchOut
                    )
                } catch let error as MeetingPhotoValidationError {
                    lastError = error.localizedDescription
                    throw OfflineMeetingError.photoValidation(error)
                }
            }
            let stored = try artifacts.write(
                meetingID: record.id,
                kind: kind,
                data: data,
                sourceExtension: fileExtension
            )
            switch kind {
            case .notes:
                record.notesLocalPath = stored.absoluteURL.path
                record.notesSHA256 = stored.sha256
                record.agendaNotes = String(data: data, encoding: .utf8) ?? ""
            case .receipt:
                record.receiptLocalPath = stored.absoluteURL.path
                record.receiptSHA256 = stored.sha256
            case .environmentPhoto:
                record.photoLocalPath = stored.absoluteURL.path
                record.photoSHA256 = stored.sha256
            }
            try store.upsert(record)
            active = record
            lastError = nil
            return stored
        }
    }

    @discardableResult
    public func submit() throws -> OfflineMeetingRecord {
        try withLock {
            guard var record = active else {
                lastError = OfflineMeetingError.noActiveMeeting.localizedDescription
                throw OfflineMeetingError.noActiveMeeting
            }
            guard !record.isSubmitted else {
                lastError = OfflineMeetingError.alreadySubmitted.localizedDescription
                throw OfflineMeetingError.alreadySubmitted
            }
            guard record.punchOutUTC != nil, record.punchOutMonotonic != nil else {
                lastError = OfflineMeetingError.notPunchedOut.localizedDescription
                throw OfflineMeetingError.notPunchedOut
            }
            let missing = record.missingArtifacts
            if !missing.isEmpty {
                lastError = OfflineMeetingError.missingArtifacts(missing).localizedDescription
                throw OfflineMeetingError.missingArtifacts(missing)
            }
            guard let photoPath = record.photoLocalPath,
                  let punchOut = record.punchOutUTC
            else {
                lastError = OfflineMeetingError.missingArtifacts([.environmentPhoto]).localizedDescription
                throw OfflineMeetingError.missingArtifacts([.environmentPhoto])
            }
            let photoData = try artifacts.load(kind: .environmentPhoto, path: photoPath)
            do {
                _ = try photoValidator.validate(
                    imageData: photoData,
                    punchIn: record.punchInUTC,
                    punchOut: punchOut
                )
            } catch let error as MeetingPhotoValidationError {
                lastError = error.localizedDescription
                throw OfflineMeetingError.photoValidation(error)
            }

            record.auditStatus = .pending
            record.artifactsPurgeDate = punchOut.addingTimeInterval(OfflineMeetingPolicy.artifactRetention)
            try store.upsert(record)
            active = record
            lastError = nil
            return record
        }
    }

    @discardableResult
    public func abandon() throws -> OfflineMeetingRecord {
        try withLock {
            guard var record = active, !record.isSubmitted else {
                lastError = OfflineMeetingError.noActiveMeeting.localizedDescription
                throw OfflineMeetingError.noActiveMeeting
            }
            record.auditStatus = .abandoned
            record.punchOutUTC = record.punchOutUTC ?? wallClock.now()
            record.punchOutMonotonic = record.punchOutMonotonic ?? clock.nowSeconds()
            try store.upsert(record)
            active = nil
            lastError = nil
            return record
        }
    }

    public func snapshot() -> OfflineMeetingSnapshot {
        withLock {
            OfflineMeetingSnapshot.assemble(
                record: active,
                nowMonotonic: clock.nowSeconds(),
                lastError: lastError
            )
        }
    }

    public func togglePunch() throws -> OfflineMeetingRecord {
        if let active, active.isRecording {
            return try punchOut()
        }
        return try punchIn()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
