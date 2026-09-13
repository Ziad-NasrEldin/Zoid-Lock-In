import CryptoKit
import Foundation

/// Local duration and retention rules for offline professional meetings.
public enum OfflineMeetingPolicy: Sendable {
    /// Minimum punched duration before punch-out is accepted.
    public static let minimumDuration: TimeInterval = 15 * 60
    /// Maximum punched duration; longer sessions are rejected.
    public static let maximumDuration: TimeInterval = 240 * 60
    /// Environment-photo capture time may land this far after punch-out.
    public static let photoTimestampLeeway: TimeInterval = 15 * 60
    /// Raw binaries are eligible for deletion this long after submission.
    public static let artifactRetention: TimeInterval = 30 * 24 * 60 * 60
    /// `CLOCK_MONOTONIC` sleep must stay at or under this fraction of the meeting.
    public static let maximumSleepFraction: Double = 0.20
    /// Awake `CLOCK_UPTIME_RAW` must cover at least the 15-minute minimum.
    public static let minimumAwakeDuration: TimeInterval = minimumDuration
    /// Environment photos must be at least this many pixels on each edge.
    public static let minimumPhotoEdge: Int = 1_000
    /// Agenda notes must contain at least this many non-whitespace characters.
    public static let minimumNotesNonWhitespaceCharacters = 120
    /// Agenda notes must contain at least this many letters (rejects punctuation stubs).
    public static let minimumNotesLetterCharacters = 80
    /// Agenda notes must have at least this many non-empty lines.
    public static let minimumNotesNonEmptyLines = 2

    public static func durationIsWithinLimits(_ duration: TimeInterval) -> Bool {
        duration + 0.000_1 >= minimumDuration && duration - 0.000_1 <= maximumDuration
    }

    public static func sleepIsExcessive(sleepSeconds: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 0 else { return sleepSeconds > 0.000_1 }
        return sleepSeconds > (duration * maximumSleepFraction) + 0.000_1
    }

    public static func awakeIsInsufficient(_ awakeSeconds: TimeInterval) -> Bool {
        awakeSeconds + 0.000_1 < minimumAwakeDuration
    }
}

/// Substance checks for the Markdown agenda so a punctuation stub cannot pass the gate.
public enum MeetingNotesPolicy: Sendable {
    public static func validate(_ text: String) throws {
        let stripped = Self.stripInvisible(text)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OfflineMeetingError.invalidArtifact(.notes, reason: "agenda notes are empty")
        }
        let nonWhitespace = trimmed.filter { !$0.isWhitespace && !$0.isNewline }
        if nonWhitespace.count < OfflineMeetingPolicy.minimumNotesNonWhitespaceCharacters {
            throw OfflineMeetingError.invalidArtifact(
                .notes,
                reason: "agenda notes need at least \(OfflineMeetingPolicy.minimumNotesNonWhitespaceCharacters) non-whitespace characters"
            )
        }
        let letterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letterCount < OfflineMeetingPolicy.minimumNotesLetterCharacters {
            throw OfflineMeetingError.invalidArtifact(
                .notes,
                reason: "agenda notes look like a punctuation stub or placeholder"
            )
        }
        let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count < OfflineMeetingPolicy.minimumNotesNonEmptyLines {
            throw OfflineMeetingError.invalidArtifact(
                .notes,
                reason: "agenda notes must be multi-line (heading plus body)"
            )
        }
    }

    public static func stripInvisible(_ text: String) -> String {
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
        return String(text.unicodeScalars.filter { !invisible.contains($0) })
    }
}

/// Gemini (and local) audit lifecycle. Slice 7 writes Flash/Pro terminal states.
public enum OfflineMeetingAuditStatus: String, Sendable, Equatable, Codable {
    case inProgress = "IN_PROGRESS"
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case appealed = "APPEALED"
    case arbitratedApproved = "ARBITRATED_APPROVED"
    case sealedRejected = "SEALED_REJECTED"
    case abandoned = "ABANDONED"

    /// Terminal rows cannot be re-audited or appealed.
    public var isTerminal: Bool {
        switch self {
        case .approved, .arbitratedApproved, .sealedRejected, .abandoned:
            return true
        case .inProgress, .pending, .rejected, .appealed:
            return false
        }
    }

    public func liveCaption(denialCount: Int, creditsMinted: Double) -> String {
        switch self {
        case .inProgress:
            return "IN PROGRESS"
        case .pending:
            return "PENDING AUDIT"
        case .approved, .arbitratedApproved:
            return String(format: "APPROVED (+%0.1fc)", CreditMath.normalize(creditsMinted))
        case .rejected:
            if denialCount >= GeminiAuditPolicy.rejectionsBeforeAppeal {
                return "READY FOR PRO ARBITRATION"
            }
            let attempt = max(1, min(denialCount, GeminiAuditPolicy.rejectionsBeforeAppeal))
            return "REJECTED (Attempt \(attempt)/\(GeminiAuditPolicy.rejectionsBeforeAppeal))"
        case .appealed:
            return "PRO ARBITRATION"
        case .sealedRejected:
            return "SEALED"
        case .abandoned:
            return "ABANDONED"
        }
    }
}

/// One of the three mandatory evidence payloads.
public enum MeetingArtifactKind: String, Sendable, Equatable, CaseIterable, Codable {
    case notes
    case receipt
    case environmentPhoto = "environment_photo"

    public var displayName: String {
        switch self {
        case .notes: return "Agenda"
        case .receipt: return "Receipt"
        case .environmentPhoto: return "Photo"
        }
    }

    public var dropzoneCaption: String {
        switch self {
        case .notes: return "notes.md"
        case .receipt: return "receipt.jpg · png · pdf"
        case .environmentPhoto: return "environment.jpg · heic"
        }
    }

    public func allows(fileExtension: String) -> Bool {
        let ext = Self.normalizedExtension(fileExtension)
        switch self {
        case .notes:
            return ext == "md"
        case .receipt:
            return ["jpg", "jpeg", "png", "pdf"].contains(ext)
        case .environmentPhoto:
            return ["jpg", "jpeg", "heic", "heif"].contains(ext)
        }
    }

    public func canonicalFileName(fileExtension: String) -> String {
        let ext = Self.canonicalExtension(fileExtension)
        switch self {
        case .notes:
            return "notes.md"
        case .receipt:
            return "receipt.\(ext)"
        case .environmentPhoto:
            return "environment.\(ext)"
        }
    }

    public static func normalizedExtension(_ fileExtension: String) -> String {
        fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public static func canonicalExtension(_ fileExtension: String) -> String {
        let ext = normalizedExtension(fileExtension)
        switch ext {
        case "jpeg":
            return "jpg"
        case "heif":
            return "heic"
        default:
            return ext
        }
    }
}

/// SHA-256 hex digest of an evidence file.
public enum ArtifactDigest: Sendable {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hex(data)
    }
}

/// Default on-disk tree: `~/Library/Application Support/ZoidLockIn/meetings/<id>/`.
public enum MeetingArtifactLocation: Sendable {
    public static let folderName = "meetings"

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent(EconomicLedgerLocation.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func directory(for meetingID: UUID, root: URL) -> URL {
        root.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    public static func makeIsolatedRoot(fileManager: FileManager = .default) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-meetings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// Local-gate and workflow failures. Gemini arbitration lives in Slice 7.
public enum OfflineMeetingError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case notPunchedOut
    case alreadySubmitted
    case noActiveMeeting
    case durationTooShort(TimeInterval)
    case durationTooLong(TimeInterval)
    case bootSessionChanged
    case missingArtifacts([MeetingArtifactKind])
    case invalidArtifact(MeetingArtifactKind, reason: String)
    case photoValidation(MeetingPhotoValidationError)
    case storageFailed(String)
    case clockTampered(skewSeconds: TimeInterval)
    case excessiveSleep(sleepSeconds: TimeInterval, awakeSeconds: TimeInterval, duration: TimeInterval)
    case duplicateArtifact(MeetingArtifactKind)
    case artifactHashMismatch(MeetingArtifactKind)
    case meetingNotFound
    case meetingSealed
    case appealLocked(denialCount: Int)
    case appealStatementEmpty
    case alreadyResolved
}

extension OfflineMeetingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "An offline meeting is already punched in."
        case .notRecording:
            return "Punch in before punching out."
        case .notPunchedOut:
            return "Punch out before submitting the evidence bundle."
        case .alreadySubmitted:
            return "This meeting has already been submitted."
        case .noActiveMeeting:
            return "No offline meeting is in progress."
        case .durationTooShort(let duration):
            let minutes = Int((OfflineMeetingPolicy.minimumDuration / 60).rounded())
            return "Meeting duration \(Self.formatMinutes(duration)) is under the \(minutes)-minute minimum."
        case .durationTooLong(let duration):
            let minutes = Int((OfflineMeetingPolicy.maximumDuration / 60).rounded())
            return "Meeting duration \(Self.formatMinutes(duration)) exceeds the \(minutes)-minute maximum."
        case .bootSessionChanged:
            return "The meeting spanned a reboot; monotonic punch-out is refused."
        case .missingArtifacts(let kinds):
            let names = kinds.map(\.displayName).joined(separator: ", ")
            return "Triple-artifact gate failed. Missing: \(names)."
        case .invalidArtifact(let kind, let reason):
            return "\(kind.displayName) rejected: \(reason)"
        case .photoValidation(let error):
            return error.errorDescription
        case .storageFailed(let message):
            return "Meeting artifact storage failed: \(message)"
        case .clockTampered(let skew):
            return "Clock tamper lock: wall clock diverged from the monotonic baseline by \(Int(skew.rounded(.up)))s."
        case .excessiveSleep(let sleepSeconds, let awakeSeconds, let duration):
            let sleepMin = String(format: "%0.1f", sleepSeconds / 60)
            let awakeMin = String(format: "%0.1f", awakeSeconds / 60)
            let durationMin = String(format: "%0.1f", duration / 60)
            return "Meeting sleep (\(sleepMin) min asleep / \(awakeMin) min awake of \(durationMin) min) exceeds the awake-uptime gate."
        case .duplicateArtifact(let kind):
            return "\(kind.displayName) SHA-256 was already used by another meeting."
        case .artifactHashMismatch(let kind):
            return "\(kind.displayName) on disk no longer matches the stored SHA-256 digest."
        case .meetingNotFound:
            return "That offline meeting was not found."
        case .meetingSealed:
            return "This meeting is permanently sealed. Further submissions and appeals are blocked."
        case .appealLocked(let count):
            return "Appeal to Gemini Pro unlocks after \(GeminiAuditPolicy.rejectionsBeforeAppeal) consecutive rejections (currently \(count))."
        case .appealStatementEmpty:
            return "Appeal explanation is empty after sanitization."
        case .alreadyResolved:
            return "This meeting has already been resolved."
        }
    }

    private static func formatMinutes(_ duration: TimeInterval) -> String {
        String(format: "%0.1f min", duration / 60)
    }
}

/// Persistent offline-meeting row. Hashes and metadata survive the 30-day binary purge.
public struct OfflineMeetingRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var punchInUTC: Date
    public var punchOutUTC: Date?
    public var punchInMonotonic: TimeInterval
    public var punchOutMonotonic: TimeInterval?
    public var punchInUptime: TimeInterval
    public var punchOutUptime: TimeInterval?
    public var durationSeconds: TimeInterval
    public var bootSessionUUID: String
    public var agendaNotes: String
    public var notesSHA256: String?
    public var receiptSHA256: String?
    public var photoSHA256: String?
    public var notesLocalPath: String?
    public var receiptLocalPath: String?
    public var photoLocalPath: String?
    public var artifactsPurgeDate: Date?
    public var artifactsPurgedAt: Date?
    public var auditStatus: OfflineMeetingAuditStatus
    public var denialCount: Int
    public var aiReasoning: String?
    public var detectedInconsistencies: [String]
    public var appealStatement: String?
    public var creditsMinted: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        punchInUTC: Date,
        punchOutUTC: Date? = nil,
        punchInMonotonic: TimeInterval,
        punchOutMonotonic: TimeInterval? = nil,
        punchInUptime: TimeInterval? = nil,
        punchOutUptime: TimeInterval? = nil,
        durationSeconds: TimeInterval = 0,
        bootSessionUUID: String,
        agendaNotes: String = "",
        notesSHA256: String? = nil,
        receiptSHA256: String? = nil,
        photoSHA256: String? = nil,
        notesLocalPath: String? = nil,
        receiptLocalPath: String? = nil,
        photoLocalPath: String? = nil,
        artifactsPurgeDate: Date? = nil,
        artifactsPurgedAt: Date? = nil,
        auditStatus: OfflineMeetingAuditStatus = .inProgress,
        denialCount: Int = 0,
        aiReasoning: String? = nil,
        detectedInconsistencies: [String] = [],
        appealStatement: String? = nil,
        creditsMinted: Double = 0,
        createdAt: Date
    ) {
        self.id = id
        self.punchInUTC = punchInUTC
        self.punchOutUTC = punchOutUTC
        self.punchInMonotonic = punchInMonotonic
        self.punchOutMonotonic = punchOutMonotonic
        self.punchInUptime = punchInUptime ?? punchInMonotonic
        self.punchOutUptime = punchOutUptime
        self.durationSeconds = durationSeconds
        self.bootSessionUUID = bootSessionUUID
        self.agendaNotes = agendaNotes
        self.notesSHA256 = notesSHA256
        self.receiptSHA256 = receiptSHA256
        self.photoSHA256 = photoSHA256
        self.notesLocalPath = notesLocalPath
        self.receiptLocalPath = receiptLocalPath
        self.photoLocalPath = photoLocalPath
        self.artifactsPurgeDate = artifactsPurgeDate
        self.artifactsPurgedAt = artifactsPurgedAt
        self.auditStatus = auditStatus
        self.denialCount = denialCount
        self.aiReasoning = aiReasoning
        self.detectedInconsistencies = detectedInconsistencies
        self.appealStatement = appealStatement
        self.creditsMinted = CreditMath.normalize(creditsMinted)
        self.createdAt = createdAt
    }

    public var liveAuditCaption: String {
        auditStatus.liveCaption(denialCount: denialCount, creditsMinted: creditsMinted)
    }

    public var canAppealToPro: Bool {
        auditStatus == .rejected && denialCount == GeminiAuditPolicy.rejectionsBeforeAppeal
    }

    public var canRetryFlashAudit: Bool {
        switch auditStatus {
        case .rejected:
            return denialCount > 0 && denialCount < GeminiAuditPolicy.rejectionsBeforeAppeal
        case .pending, .inProgress, .approved, .appealed, .arbitratedApproved, .sealedRejected, .abandoned:
            return false
        }
    }

    public var isRecording: Bool {
        punchOutUTC == nil && auditStatus == .inProgress
    }

    public var isSubmitted: Bool {
        auditStatus != .inProgress && auditStatus != .abandoned
    }

    public func sha256(for kind: MeetingArtifactKind) -> String? {
        switch kind {
        case .notes: return notesSHA256
        case .receipt: return receiptSHA256
        case .environmentPhoto: return photoSHA256
        }
    }

    public func localPath(for kind: MeetingArtifactKind) -> String? {
        switch kind {
        case .notes: return notesLocalPath
        case .receipt: return receiptLocalPath
        case .environmentPhoto: return photoLocalPath
        }
    }

    public var missingArtifacts: [MeetingArtifactKind] {
        MeetingArtifactKind.allCases.filter { kind in
            switch kind {
            case .notes:
                return notesLocalPath == nil || notesSHA256 == nil || agendaNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .receipt:
                return receiptLocalPath == nil || receiptSHA256 == nil
            case .environmentPhoto:
                return photoLocalPath == nil || photoSHA256 == nil
            }
        }
    }
}
