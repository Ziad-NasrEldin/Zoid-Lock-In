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

    public static func durationIsWithinLimits(_ duration: TimeInterval) -> Bool {
        duration + 0.000_1 >= minimumDuration && duration - 0.000_1 <= maximumDuration
    }
}

/// Gemini (and local) audit lifecycle. Slice 6 writes `IN_PROGRESS` and `PENDING`.
public enum OfflineMeetingAuditStatus: String, Sendable, Equatable, Codable {
    case inProgress = "IN_PROGRESS"
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case appealed = "APPEALED"
    case appealApproved = "APPEAL_APPROVED"
    case sealedRejected = "SEALED_REJECTED"
    case abandoned = "ABANDONED"
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
    public var creditsMinted: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        punchInUTC: Date,
        punchOutUTC: Date? = nil,
        punchInMonotonic: TimeInterval,
        punchOutMonotonic: TimeInterval? = nil,
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
        creditsMinted: Double = 0,
        createdAt: Date
    ) {
        self.id = id
        self.punchInUTC = punchInUTC
        self.punchOutUTC = punchOutUTC
        self.punchInMonotonic = punchInMonotonic
        self.punchOutMonotonic = punchOutMonotonic
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
        self.creditsMinted = CreditMath.normalize(creditsMinted)
        self.createdAt = createdAt
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
