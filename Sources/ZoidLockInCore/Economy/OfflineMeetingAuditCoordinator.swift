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
        try await auditFlash(meetingID: meetingID)
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

            if model == .pro {
                var appealing = record
                appealing.auditStatus = .appealed
                appealing.appealStatement = appealStatement
                try store.applyAuditLifecycle(appealing)
                refreshSession(appealing)
            }

            let evidence = try makeEvidence(record, appealStatement: appealStatement)
            let verdict = try await client.audit(evidence, model: model)
            let updated = try persist(verdict: verdict, on: record, model: model, appealStatement: appealStatement)
            session?.setLastError(nil)
            refreshSession(updated)
            return updated
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            session?.setLastError(message)
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
        try engine.ledger.performAtomically {
            var next = record
            let reference = record.id.uuidString
            if let existing = try engine.ledger.allTransactions().first(where: {
                $0.transactionType == .earnedMeeting && $0.referenceID == reference
            }) {
                next.creditsMinted = existing.amount
            } else {
                let amount = MeetingCreditMinting.credits(durationSeconds: record.durationSeconds)
                if amount > 0 {
                    let balance = try engine.ledger.latestBalance()
                    let transaction = WalletTransaction(
                        timestamp: engine.wallTime(),
                        amount: amount,
                        balanceAfter: CreditMath.normalize(balance + amount),
                        transactionType: .earnedMeeting,
                        referenceID: reference,
                        description: "EARNED_MEETING +\(CreditMath.normalize(amount)) (\(Int(record.durationSeconds.rounded(.down)))s)"
                    )
                    try engine.ledger.appendTransaction(transaction)
                    next.creditsMinted = amount
                } else {
                    next.creditsMinted = 0
                }
            }
            try store.applyAuditLifecycle(next)
            return next
        }
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
            throw OfflineMeetingError.alreadyResolved
        }
        inFlight = true
    }

    private func endFlight() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}
