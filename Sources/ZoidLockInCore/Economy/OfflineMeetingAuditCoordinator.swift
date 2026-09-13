import Foundation

/// Applies Gemini Flash / Pro verdicts to SQLite meeting rows and the daily ledger.
public final class OfflineMeetingAuditCoordinator: @unchecked Sendable {
    public let store: any OfflineMeetingStoring
    public let artifacts: MeetingArtifactStore
    public let engine: ExchangeEngine
    public let client: GeminiAuditClient

    public weak var session: OfflineSessionCoordinator?

    private let lock = NSLock()
    private var inFlight = false

    public init(
        store: any OfflineMeetingStoring,
        artifacts: MeetingArtifactStore,
        engine: ExchangeEngine,
        client: GeminiAuditClient,
        session: OfflineSessionCoordinator? = nil
    ) {
        self.store = store
        self.artifacts = artifacts
        self.engine = engine
        self.client = client
        self.session = session
    }

    @discardableResult
    public func auditFlash(meetingID: UUID) async throws -> OfflineMeetingRecord {
        try await dispatch(meetingID: meetingID, model: .flash, appealStatement: nil)
    }

    @discardableResult
    public func retryFlash(meetingID: UUID) async throws -> OfflineMeetingRecord {
        try await retryAudit(meetingID: meetingID)
    }

    /// Retries Flash for pending/rejected meetings, or Pro when the row is already `APPEALED`.
    @discardableResult
    public func retryAudit(meetingID: UUID) async throws -> OfflineMeetingRecord {
        let record = try loadMeeting(id: meetingID)
        switch record.auditStatus {
        case .appealed:
            let fallback = "Retrying Gemini Pro arbitration after a transient audit failure."
            let statement = record.appealStatement.flatMap { raw in
                let sanitized = PromptInjectionSanitizer.sanitizeAppeal(raw)
                return sanitized.isEmpty ? nil : sanitized
            } ?? fallback
            return try await dispatch(meetingID: meetingID, model: .pro, appealStatement: statement)
        case .pending, .rejected:
            return try await auditFlash(meetingID: meetingID)
        case .sealedRejected:
            throw OfflineMeetingError.meetingSealed
        case .inProgress, .approved, .arbitratedApproved, .abandoned:
            throw OfflineMeetingError.alreadyResolved
        }
    }

    @discardableResult
    public func appealToPro(meetingID: UUID, statement: String) async throws -> OfflineMeetingRecord {
        let sanitized = PromptInjectionSanitizer.sanitizeAppeal(statement)
        guard !sanitized.isEmpty else {
            let error = OfflineMeetingError.appealStatementEmpty
            session?.setLastError(error.localizedDescription)
            throw error
        }
        return try await dispatch(meetingID: meetingID, model: .pro, appealStatement: sanitized)
    }

    private func dispatch(
        meetingID: UUID,
        model: GeminiAuditModel,
        appealStatement: String?
    ) async throws -> OfflineMeetingRecord {
        try beginFlight()
        defer { endFlight() }

        do {
            try engine.ensureEconomyWritable()
            let record = try loadMeeting(id: meetingID)
            try validateTransition(record, model: model, appealing: appealStatement != nil)

            var attempting = record
            if model == .pro {
                attempting.auditStatus = .appealed
                attempting.appealStatement = appealStatement
            }
            attempting.auditAttemptCount = record.auditAttemptCount + 1
            attempting.lastAuditAttemptedAt = engine.wallTime()
            try store.applyAuditLifecycle(attempting)
            refreshSession(attempting)

            let evidence = try makeEvidence(attempting, appealStatement: appealStatement)
            let verdict = try await client.audit(evidence, model: model)
            let updated = try persist(
                verdict: verdict,
                on: attempting,
                model: model,
                appealStatement: appealStatement
            )
            session?.setLastError(nil)
            refreshSession(updated)
            return updated
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            session?.setLastError(message)
            if Self.shouldPersistAuditFailure(error) {
                persistAuditFailure(meetingID: meetingID, message: message)
            }
            throw error
        }
    }

    private func validateTransition(
        _ record: OfflineMeetingRecord,
        model: GeminiAuditModel,
        appealing: Bool
    ) throws {
        if record.auditStatus == .sealedRejected {
            throw OfflineMeetingError.meetingSealed
        }
        if record.auditStatus.isTerminal {
            throw OfflineMeetingError.alreadyResolved
        }
        switch model {
        case .flash:
            if appealing {
                throw OfflineMeetingError.alreadyResolved
            }
            switch record.auditStatus {
            case .pending:
                return
            case .rejected:
                if record.denialCount >= GeminiAuditPolicy.rejectionsBeforeAppeal {
                    throw OfflineMeetingError.appealLocked(denialCount: record.denialCount)
                }
                return
            default:
                throw OfflineMeetingError.alreadyResolved
            }
        case .pro:
            guard record.canAppealToPro || record.auditStatus == .appealed else {
                throw OfflineMeetingError.appealLocked(denialCount: record.denialCount)
            }
            if record.auditStatus == .rejected {
                guard record.denialCount == GeminiAuditPolicy.rejectionsBeforeAppeal else {
                    throw OfflineMeetingError.appealLocked(denialCount: record.denialCount)
                }
            }
        }
    }

    private func persist(
        verdict: GeminiAuditVerdict,
        on record: OfflineMeetingRecord,
        model: GeminiAuditModel,
        appealStatement: String?
    ) throws -> OfflineMeetingRecord {
        var next = record
        next.aiReasoning = verdict.rationale
        next.detectedInconsistencies = verdict.detectedInconsistencies
        next.lastAuditError = nil
        if let appealStatement {
            next.appealStatement = appealStatement
        }

        let eligible = verdict.isCreditEligible
        if eligible {
            next.auditStatus = model == .pro ? .arbitratedApproved : .approved
            return try persistApproval(next)
        }

        if model == .pro {
            next.auditStatus = .sealedRejected
            try store.applyAuditLifecycle(next)
            return next
        }

        next.auditStatus = .rejected
        next.denialCount = min(record.denialCount + 1, GeminiAuditPolicy.rejectionsBeforeAppeal)
        if verdict.decision == .approved {
            next.aiReasoning = "Confidence \(String(format: "%0.2f", verdict.confidenceScore)) is below \(GeminiAuditPolicy.approvalConfidenceFloor). \(verdict.rationale)"
        }
        try store.applyAuditLifecycle(next)
        return next
    }

    private func persistApproval(_ record: OfflineMeetingRecord) throws -> OfflineMeetingRecord {
        try engine.mintEarnedMeetingAndThen(
            meetingID: record.id,
            durationSeconds: record.durationSeconds
        ) { outcome in
            var next = record
            next.creditsMinted = outcome.creditsMinted
            next.lastAuditError = nil
            if let explanation = outcome.explanation, !explanation.isEmpty {
                let prior = next.aiReasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                next.aiReasoning = prior.isEmpty ? explanation : prior + "\n" + explanation
            }
            try store.applyAuditLifecycle(next)
            return next
        }
    }

    private func persistAuditFailure(meetingID: UUID, message: String) {
        guard var failed = try? store.meeting(id: meetingID) else { return }
        failed.lastAuditError = message
        failed.lastAuditAttemptedAt = engine.wallTime()
        try? store.applyAuditLifecycle(failed)
        refreshSession(failed)
    }

    private static func shouldPersistAuditFailure(_ error: Error) -> Bool {
        if error is GeminiAuditError {
            return true
        }
        if error is URLError {
            return true
        }
        if let meeting = error as? OfflineMeetingError {
            switch meeting {
            case .auditInFlight, .alreadyResolved, .meetingSealed, .appealLocked, .appealStatementEmpty:
                return false
            default:
                return true
            }
        }
        return true
    }

    private func makeEvidence(
        _ record: OfflineMeetingRecord,
        appealStatement: String?
    ) throws -> GeminiAuditEvidence {
        guard let punchOut = record.punchOutUTC else {
            throw OfflineMeetingError.notPunchedOut
        }
        guard let receiptPath = record.receiptLocalPath, let photoPath = record.photoLocalPath else {
            throw OfflineMeetingError.missingArtifacts(record.missingArtifacts)
        }
        let receiptData = try artifacts.load(kind: .receipt, path: receiptPath)
        let photoData = try artifacts.load(kind: .environmentPhoto, path: photoPath)
        let agenda: String
        if let notesPath = record.notesLocalPath, let notesData = try? artifacts.load(kind: .notes, path: notesPath),
           let text = String(data: notesData, encoding: .utf8) {
            agenda = text
        } else {
            agenda = record.agendaNotes
        }
        return GeminiAuditEvidence(
            meetingID: record.id,
            punchInUTC: record.punchInUTC,
            punchOutUTC: punchOut,
            durationSeconds: record.durationSeconds,
            agendaMarkdown: agenda,
            receipt: GeminiInlinePart(
                mimeType: GeminiAuditClient.mimeType(forPath: receiptPath, kind: .receipt),
                data: receiptData
            ),
            environmentPhoto: GeminiInlinePart(
                mimeType: GeminiAuditClient.mimeType(forPath: photoPath, kind: .environmentPhoto),
                data: photoData
            ),
            priorRationale: record.aiReasoning,
            priorInconsistencies: record.detectedInconsistencies,
            denialCount: record.denialCount,
            appealStatement: appealStatement
        )
    }

    private func loadMeeting(id: UUID) throws -> OfflineMeetingRecord {
        if let stored = try store.meeting(id: id) {
            return stored
        }
        throw OfflineMeetingError.meetingNotFound
    }

    private func refreshSession(_ record: OfflineMeetingRecord) {
        session?.replaceActive(with: record)
    }

    private func beginFlight() throws {
        lock.lock()
        defer { lock.unlock() }
        if inFlight {
            throw OfflineMeetingError.auditInFlight
        }
        inFlight = true
    }

    private func endFlight() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}
