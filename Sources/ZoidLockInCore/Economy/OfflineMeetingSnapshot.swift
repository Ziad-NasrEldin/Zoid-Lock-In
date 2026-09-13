import Foundation

/// Visual state for one dropzone cell in the SUMI-E meeting sheet.
public struct MeetingArtifactStatus: Sendable, Equatable, Identifiable {
    public var kind: MeetingArtifactKind
    public var isPresent: Bool
    public var isValid: Bool
    public var filename: String?
    public var sha256: String?
    public var caption: String

    public var id: MeetingArtifactKind { kind }

    public init(
        kind: MeetingArtifactKind,
        isPresent: Bool,
        isValid: Bool,
        filename: String?,
        sha256: String?,
        caption: String
    ) {
        self.kind = kind
        self.isPresent = isPresent
        self.isValid = isValid
        self.filename = filename
        self.sha256 = sha256
        self.caption = caption
    }

    public var shortDigest: String? {
        guard let sha256, sha256.count >= 12 else { return sha256 }
        return String(sha256.prefix(12))
    }
}

public enum OfflineMeetingPhase: String, Sendable, Equatable {
    case idle
    case recording
    case awaitingEvidence
    case submitted
}

/// View model for the native SUMI-E Offline Meeting popover.
public struct OfflineMeetingSnapshot: Sendable, Equatable {
    public var phase: OfflineMeetingPhase
    public var meetingID: UUID?
    public var elapsedSeconds: TimeInterval
    public var elapsedCaption: String
    public var punchInCaption: String?
    public var punchOutCaption: String?
    public var durationCaption: String?
    public var notes: MeetingArtifactStatus
    public var receipt: MeetingArtifactStatus
    public var photo: MeetingArtifactStatus
    public var canPunchIn: Bool
    public var canPunchOut: Bool
    public var canSubmit: Bool
    public var canAbandon: Bool
    public var punchButtonTitle: String
    public var submissionCaption: String
    public var auditStatusCaption: String
    public var retentionCaption: String
    public var lastError: String?
    public var geminiRationale: String?
    public var detectedInconsistencies: [String]
    public var canAppeal: Bool
    public var canRetryAudit: Bool
    public var denialCount: Int
    public var creditsMinted: Double

    public init(
        phase: OfflineMeetingPhase,
        meetingID: UUID?,
        elapsedSeconds: TimeInterval,
        elapsedCaption: String,
        punchInCaption: String?,
        punchOutCaption: String?,
        durationCaption: String?,
        notes: MeetingArtifactStatus,
        receipt: MeetingArtifactStatus,
        photo: MeetingArtifactStatus,
        canPunchIn: Bool,
        canPunchOut: Bool,
        canSubmit: Bool,
        canAbandon: Bool,
        punchButtonTitle: String,
        submissionCaption: String,
        auditStatusCaption: String,
        retentionCaption: String,
        lastError: String?,
        geminiRationale: String? = nil,
        detectedInconsistencies: [String] = [],
        canAppeal: Bool = false,
        canRetryAudit: Bool = false,
        denialCount: Int = 0,
        creditsMinted: Double = 0
    ) {
        self.phase = phase
        self.meetingID = meetingID
        self.elapsedSeconds = elapsedSeconds
        self.elapsedCaption = elapsedCaption
        self.punchInCaption = punchInCaption
        self.punchOutCaption = punchOutCaption
        self.durationCaption = durationCaption
        self.notes = notes
        self.receipt = receipt
        self.photo = photo
        self.canPunchIn = canPunchIn
        self.canPunchOut = canPunchOut
        self.canSubmit = canSubmit
        self.canAbandon = canAbandon
        self.punchButtonTitle = punchButtonTitle
        self.submissionCaption = submissionCaption
        self.auditStatusCaption = auditStatusCaption
        self.retentionCaption = retentionCaption
        self.lastError = lastError
        self.geminiRationale = geminiRationale
        self.detectedInconsistencies = detectedInconsistencies
        self.canAppeal = canAppeal
        self.canRetryAudit = canRetryAudit
        self.denialCount = denialCount
        self.creditsMinted = CreditMath.normalize(creditsMinted)
    }

    public var artifacts: [MeetingArtifactStatus] {
        [notes, receipt, photo]
    }

    public static func formattedElapsed(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainder = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }

    public static func assemble(
        record: OfflineMeetingRecord?,
        nowMonotonic: TimeInterval,
        lastError: String?
    ) -> OfflineMeetingSnapshot {
        guard let record else {
            return idle(lastError: lastError)
        }

        let elapsed: TimeInterval
        if let punched = record.punchOutMonotonic {
            elapsed = max(0, punched - record.punchInMonotonic)
        } else {
            elapsed = max(0, nowMonotonic - record.punchInMonotonic)
        }

        let phase: OfflineMeetingPhase
        if record.isSubmitted {
            phase = .submitted
        } else if record.punchOutUTC == nil {
            phase = .recording
        } else {
            phase = .awaitingEvidence
        }

        let notes = status(
            kind: .notes,
            path: record.notesLocalPath,
            sha: record.notesSHA256,
            submitted: record.isSubmitted
        )
        let receipt = status(
            kind: .receipt,
            path: record.receiptLocalPath,
            sha: record.receiptSHA256,
            submitted: record.isSubmitted
        )
        let photo = status(
            kind: .environmentPhoto,
            path: record.photoLocalPath,
            sha: record.photoSHA256,
            submitted: record.isSubmitted
        )

        let missing = record.missingArtifacts
        let canSubmit = phase == .awaitingEvidence && missing.isEmpty
        let punchTitle: String
        switch phase {
        case .idle, .submitted:
            punchTitle = "PUNCH IN"
        case .recording:
            punchTitle = "PUNCH OUT"
        case .awaitingEvidence:
            punchTitle = "PUNCHED"
        }

        let submission: String
        switch phase {
        case .idle:
            submission = "IDLE · PUNCH IN TO START"
        case .recording:
            submission = "RECORDING · CLOCK_MONOTONIC"
        case .awaitingEvidence:
            submission = missing.isEmpty
                ? "TRIPLE ARTIFACT READY · SUBMIT"
                : "AWAITING \(missing.map { $0.displayName.uppercased() }.joined(separator: " · "))"
        case .submitted:
            switch record.auditStatus {
            case .approved, .arbitratedApproved:
                submission = String(
                    format: "APPROVED · +%0.1fc MINTED",
                    CreditMath.normalize(record.creditsMinted)
                )
            case .rejected where record.canAppealToPro:
                submission = "READY FOR PRO ARBITRATION"
            case .rejected:
                submission = "REJECTED · FLASH AUDIT"
            case .appealed:
                submission = "APPEALED · GEMINI PRO"
            case .sealedRejected:
                submission = "SEALED · NO FURTHER CLAIMS"
            default:
                submission = "SUBMITTED · PENDING GEMINI"
            }
        }

        return OfflineMeetingSnapshot(
            phase: phase,
            meetingID: record.id,
            elapsedSeconds: elapsed,
            elapsedCaption: formattedElapsed(elapsed),
            punchInCaption: Self.shortUTC(record.punchInUTC),
            punchOutCaption: record.punchOutUTC.map(Self.shortUTC),
            durationCaption: phase == .recording
                ? "IN SESSION · 15–240 MIN GATE"
                : String(format: "%d min · 15–240 gate", Int((elapsed / 60).rounded(.down))),
            notes: notes,
            receipt: receipt,
            photo: photo,
            canPunchIn: phase == .idle || (phase == .submitted && record.auditStatus.isTerminal && record.auditStatus != .abandoned),
            canPunchOut: phase == .recording,
            canSubmit: canSubmit,
            canAbandon: phase == .recording || phase == .awaitingEvidence,
            punchButtonTitle: punchTitle,
            submissionCaption: submission,
            auditStatusCaption: record.liveAuditCaption,
            retentionCaption: "RAW ARTIFACTS PURGE 30 DAYS",
            lastError: lastError,
            geminiRationale: record.aiReasoning,
            detectedInconsistencies: record.detectedInconsistencies,
            canAppeal: record.canAppealToPro,
            canRetryAudit: record.canRetryFlashAudit || (phase == .submitted && record.auditStatus == .pending && lastError != nil),
            denialCount: record.denialCount,
            creditsMinted: record.creditsMinted
        )
    }

    public static let idle = OfflineMeetingSnapshot.idle(lastError: nil)

    public static func idle(lastError: String?) -> OfflineMeetingSnapshot {
        OfflineMeetingSnapshot(
            phase: .idle,
            meetingID: nil,
            elapsedSeconds: 0,
            elapsedCaption: "00:00:00",
            punchInCaption: nil,
            punchOutCaption: nil,
            durationCaption: "15 MIN MINIMUM · 240 MIN MAXIMUM",
            notes: emptyStatus(.notes),
            receipt: emptyStatus(.receipt),
            photo: emptyStatus(.environmentPhoto),
            canPunchIn: true,
            canPunchOut: false,
            canSubmit: false,
            canAbandon: false,
            punchButtonTitle: "PUNCH IN",
            submissionCaption: "IDLE · PUNCH IN TO START",
            auditStatusCaption: "STANDBY",
            retentionCaption: "RAW ARTIFACTS PURGE 30 DAYS",
            lastError: lastError,
            geminiRationale: nil,
            detectedInconsistencies: [],
            canAppeal: false,
            canRetryAudit: false,
            denialCount: 0,
            creditsMinted: 0
        )
    }

    /// Deterministic high-resolution proof: 47-minute session, triple gate green.
    public static let proof = OfflineMeetingSnapshot(
        phase: .submitted,
        meetingID: UUID(uuidString: "6E0A1111-2222-4333-8444-555566667777"),
        elapsedSeconds: 47 * 60,
        elapsedCaption: "00:47:00",
        punchInCaption: "08:12 UTC",
        punchOutCaption: "08:59 UTC",
        durationCaption: "47 min · 15–240 gate",
        notes: MeetingArtifactStatus(
            kind: .notes,
            isPresent: true,
            isValid: true,
            filename: "notes.md",
            sha256: "c0ffeeabc123def4567890aa",
            caption: "READY · notes.md"
        ),
        receipt: MeetingArtifactStatus(
            kind: .receipt,
            isPresent: true,
            isValid: true,
            filename: "receipt.pdf",
            sha256: "a11ce0b0b1e2c3d4e5f60718",
            caption: "READY · receipt.pdf"
        ),
        photo: MeetingArtifactStatus(
            kind: .environmentPhoto,
            isPresent: true,
            isValid: true,
            filename: "environment.jpg",
            sha256: "0ff1ceapplecam00aa11bb22",
            caption: "VALID · APPLE CAMERA"
        ),
        canPunchIn: false,
        canPunchOut: false,
        canSubmit: false,
        canAbandon: false,
        punchButtonTitle: "PUNCHED",
        submissionCaption: "SUBMITTED · PENDING GEMINI",
        auditStatusCaption: "PENDING AUDIT",
        retentionCaption: "RAW ARTIFACTS PURGE 30 DAYS",
        lastError: nil,
        geminiRationale: nil,
        detectedInconsistencies: [],
        canAppeal: false,
        canRetryAudit: false,
        denialCount: 0,
        creditsMinted: 0
    )

    /// Slice 7 proof: three Flash rejections unlock Gemini Pro arbitration.
    public static let geminiAuditProof = OfflineMeetingSnapshot(
        phase: .submitted,
        meetingID: UUID(uuidString: "7E0A1111-2222-4333-8444-555566667777"),
        elapsedSeconds: 60 * 60,
        elapsedCaption: "01:00:00",
        punchInCaption: "09:00 UTC",
        punchOutCaption: "10:00 UTC",
        durationCaption: "60 min · 15–240 gate",
        notes: MeetingArtifactStatus(
            kind: .notes,
            isPresent: true,
            isValid: true,
            filename: "notes.md",
            sha256: "c0ffeeabc123def4567890aa",
            caption: "READY · notes.md"
        ),
        receipt: MeetingArtifactStatus(
            kind: .receipt,
            isPresent: true,
            isValid: true,
            filename: "receipt.pdf",
            sha256: "a11ce0b0b1e2c3d4e5f60718",
            caption: "READY · receipt.pdf"
        ),
        photo: MeetingArtifactStatus(
            kind: .environmentPhoto,
            isPresent: true,
            isValid: true,
            filename: "environment.jpg",
            sha256: "0ff1ceapplecam00aa11bb22",
            caption: "VALID · APPLE CAMERA"
        ),
        canPunchIn: false,
        canPunchOut: false,
        canSubmit: false,
        canAbandon: false,
        punchButtonTitle: "PUNCHED",
        submissionCaption: "READY FOR PRO ARBITRATION",
        auditStatusCaption: "READY FOR PRO ARBITRATION",
        retentionCaption: "RAW ARTIFACTS PURGE 30 DAYS",
        lastError: nil,
        geminiRationale: "Receipt timestamp precedes punch-in by four hours, and the environment photo does not match the stated workshop venue.",
        detectedInconsistencies: [
            "Receipt date precedes punch-in",
            "Environment does not match agenda location",
        ],
        canAppeal: true,
        canRetryAudit: false,
        denialCount: 3,
        creditsMinted: 0
    )

    private static func emptyStatus(_ kind: MeetingArtifactKind) -> MeetingArtifactStatus {
        MeetingArtifactStatus(
            kind: kind,
            isPresent: false,
            isValid: false,
            filename: nil,
            sha256: nil,
            caption: "MISSING · \(kind.dropzoneCaption)"
        )
    }

    private static func status(
        kind: MeetingArtifactKind,
        path: String?,
        sha: String?,
        submitted: Bool
    ) -> MeetingArtifactStatus {
        guard let path, let sha else {
            return emptyStatus(kind)
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let caption: String
        if submitted && kind == .environmentPhoto {
            caption = "VALID · APPLE CAMERA"
        } else if submitted {
            caption = "READY · SHA-256 \(String(sha.prefix(12)))"
        } else if kind == .environmentPhoto {
            caption = "STAGED · EXIF AT SUBMIT"
        } else {
            caption = "STAGED · \(name)"
        }
        return MeetingArtifactStatus(
            kind: kind,
            isPresent: true,
            isValid: true,
            filename: name,
            sha256: sha,
            caption: caption
        )
    }

    private static func shortUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
