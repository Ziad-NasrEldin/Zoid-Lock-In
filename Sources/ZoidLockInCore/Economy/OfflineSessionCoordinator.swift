import Foundation

/// Punch-in / punch-out coordinator with a strict triple-artifact submission gate.
public final class OfflineSessionCoordinator: @unchecked Sendable {
    public let store: any OfflineMeetingStoring
    public let artifacts: MeetingArtifactStore
    public let clock: any MonotonicTimeProviding
    public let uptimeClock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let bootSessionUUID: String
    public let timeTravel: TimeTravelGuard

    /// Optional digital-focus engine. Punch-in concludes an active focus block
    /// and holds the mutex so both surfaces cannot mint the same elapsed time.
    public weak var focusEngine: ExchangeEngine?

    private let photoValidator: MeetingPhotoValidator
    private let lock = NSLock()
    private var active: OfflineMeetingRecord?
    private var lastError: String?

    public init(
        store: any OfflineMeetingStoring,
        artifacts: MeetingArtifactStore,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        uptimeClock: any MonotonicTimeProviding = MachUptimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        timeZone: TimeZone = .current,
        bootSessionUUID: String = BootSession.currentUUID()
    ) {
        self.store = store
        self.artifacts = artifacts
        self.clock = clock
        self.uptimeClock = uptimeClock
        self.wallClock = wallClock
        self.timeTravel = timeTravel
        self.bootSessionUUID = bootSessionUUID
        self.photoValidator = MeetingPhotoValidator(timeZone: timeZone)
        self.active = try? store.recordingMeeting()
    }

    public func bindFocusEngine(_ engine: ExchangeEngine) {
        focusEngine = engine
        if isPunchedIn {
            engine.beginOfflineMeetingIgnoringFocus()
        }
    }

    public var lastErrorMessage: String? {
        withLock { lastError }
    }

    public var activeMeeting: OfflineMeetingRecord? {
        withLock { active }
    }

    public var isPunchedIn: Bool {
        withLock { active?.isRecording == true }
    }

    @discardableResult
    public func punchIn() throws -> OfflineMeetingRecord {
        try ensureTimeTravel()
        if activeMeeting?.isRecording == true {
            return try withLock {
                lastError = OfflineMeetingError.alreadyRecording.localizedDescription
                throw OfflineMeetingError.alreadyRecording
            }
        }
        try focusEngine?.beginOfflineMeeting()
        do {
            return try withLock {
                if let active, active.isRecording {
                    lastError = OfflineMeetingError.alreadyRecording.localizedDescription
                    throw OfflineMeetingError.alreadyRecording
                }
                try ensureTimeTravelLocked()
                let record = OfflineMeetingRecord(
                    punchInUTC: wallClock.now(),
                    punchInMonotonic: clock.nowSeconds(),
                    punchInUptime: uptimeClock.nowSeconds(),
                    bootSessionUUID: bootSessionUUID,
                    createdAt: wallClock.now()
                )
                try store.upsert(record)
                active = record
                lastError = nil
                return record
            }
        } catch {
            if activeMeeting?.isRecording != true {
                focusEngine?.endOfflineMeeting()
            }
            throw error
        }
    }

    @discardableResult
    public func punchOut() throws -> OfflineMeetingRecord {
        try ensureTimeTravel()
        let record = try withLock {
            guard var record = active, record.isRecording else {
                lastError = OfflineMeetingError.notRecording.localizedDescription
                throw OfflineMeetingError.notRecording
            }
            guard record.bootSessionUUID == bootSessionUUID else {
                lastError = OfflineMeetingError.bootSessionChanged.localizedDescription
                throw OfflineMeetingError.bootSessionChanged
            }
            try ensureTimeTravelLocked()
            let punched = clock.nowSeconds()
            let punchedUptime = uptimeClock.nowSeconds()
            let duration = max(0, punched - record.punchInMonotonic)
            let awake = max(0, punchedUptime - record.punchInUptime)
            let sleepSeconds = max(0, duration - awake)
            if duration + 0.000_1 < OfflineMeetingPolicy.minimumDuration {
                lastError = OfflineMeetingError.durationTooShort(duration).localizedDescription
                throw OfflineMeetingError.durationTooShort(duration)
            }
            if duration - 0.000_1 > OfflineMeetingPolicy.maximumDuration {
                lastError = OfflineMeetingError.durationTooLong(duration).localizedDescription
                throw OfflineMeetingError.durationTooLong(duration)
            }
            if OfflineMeetingPolicy.sleepIsExcessive(sleepSeconds: sleepSeconds, duration: duration)
                || OfflineMeetingPolicy.awakeIsInsufficient(awake) {
                let error = OfflineMeetingError.excessiveSleep(
                    sleepSeconds: sleepSeconds,
                    awakeSeconds: awake,
                    duration: duration
                )
                lastError = error.localizedDescription
                throw error
            }
            record.punchOutMonotonic = punched
            record.punchOutUptime = punchedUptime
            record.punchOutUTC = wallClock.now()
            record.durationSeconds = duration
            try store.upsert(record)
            active = record
            lastError = nil
            return record
        }
        focusEngine?.endOfflineMeeting()
        return record
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
            if kind == .receipt || kind == .environmentPhoto {
                if try store.hasRegisteredArtifactHash(stored.sha256, kind: kind, excluding: record.id) {
                    lastError = OfflineMeetingError.duplicateArtifact(kind).localizedDescription
                    throw OfflineMeetingError.duplicateArtifact(kind)
                }
            }
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
            do {
                try store.upsert(record)
            } catch let error as OfflineMeetingError {
                lastError = error.localizedDescription
                throw error
            } catch let error as EconomicLedgerError {
                if case .sqlite(_, let message) = error,
                   message.localizedCaseInsensitiveContains("UNIQUE") {
                    lastError = OfflineMeetingError.duplicateArtifact(kind).localizedDescription
                    throw OfflineMeetingError.duplicateArtifact(kind)
                }
                throw OfflineMeetingError.storageFailed(error.localizedDescription)
            }
            active = record
            lastError = nil
            return stored
        }
    }

    @discardableResult
    public func submit() throws -> OfflineMeetingRecord {
        try ensureTimeTravel()
        return try withLock {
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
            try rehashAndValidateLocked(&record)
            record.auditStatus = .pending
            record.artifactsPurgeDate = record.punchOutUTC.map {
                $0.addingTimeInterval(OfflineMeetingPolicy.artifactRetention)
            }
            try store.upsert(record)
            active = record
            lastError = nil
            return record
        }
    }

    @discardableResult
    public func abandon() throws -> OfflineMeetingRecord {
        let record = try withLock {
            guard var record = active, !record.isSubmitted else {
                lastError = OfflineMeetingError.noActiveMeeting.localizedDescription
                throw OfflineMeetingError.noActiveMeeting
            }
            record.auditStatus = .abandoned
            record.punchOutUTC = record.punchOutUTC ?? wallClock.now()
            record.punchOutMonotonic = record.punchOutMonotonic ?? clock.nowSeconds()
            record.punchOutUptime = record.punchOutUptime ?? uptimeClock.nowSeconds()
            try store.upsert(record)
            active = nil
            lastError = nil
            return record
        }
        focusEngine?.endOfflineMeeting()
        return record
    }

    public func setLastError(_ message: String?) {
        withLock { lastError = message }
    }

    public func replaceActive(with record: OfflineMeetingRecord) {
        withLock {
            if active?.id == record.id || active == nil {
                active = record
            }
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

    private func rehashAndValidateLocked(_ record: inout OfflineMeetingRecord) throws {
        let kinds: [(MeetingArtifactKind, String?, String?)] = [
            (.notes, record.notesLocalPath, record.notesSHA256),
            (.receipt, record.receiptLocalPath, record.receiptSHA256),
            (.environmentPhoto, record.photoLocalPath, record.photoSHA256),
        ]
        for (kind, path, expected) in kinds {
            guard let path, let expected else {
                lastError = OfflineMeetingError.missingArtifacts([kind]).localizedDescription
                throw OfflineMeetingError.missingArtifacts([kind])
            }
            let data = try artifacts.load(kind: kind, path: path)
            let live = ArtifactDigest.sha256Hex(data)
            if live != expected {
                lastError = OfflineMeetingError.artifactHashMismatch(kind).localizedDescription
                throw OfflineMeetingError.artifactHashMismatch(kind)
            }
            if kind == .notes {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw OfflineMeetingError.invalidArtifact(.notes, reason: "notes.md must be UTF-8 markdown")
                }
                do {
                    try MeetingNotesPolicy.validate(text)
                } catch {
                    lastError = (error as? LocalizedError)?.errorDescription
                    throw error
                }
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
        }
    }

    private func ensureTimeTravel() throws {
        timeTravel.observe(wall: wallClock.now(), monotonic: clock.nowSeconds())
        do {
            try timeTravel.ensureWritable()
        } catch let TimeTravelError.clockTampered(skew) {
            let wrapped = OfflineMeetingError.clockTampered(skewSeconds: skew)
            withLock { lastError = wrapped.localizedDescription }
            throw wrapped
        }
    }

    private func ensureTimeTravelLocked() throws {
        timeTravel.observe(wall: wallClock.now(), monotonic: clock.nowSeconds())
        do {
            try timeTravel.ensureWritable()
        } catch let TimeTravelError.clockTampered(skew) {
            let wrapped = OfflineMeetingError.clockTampered(skewSeconds: skew)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
