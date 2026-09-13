import CoreGraphics
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Slice 7 adversarial hardening")
struct Slice7AdversarialHardeningTests {
    @Test("API key is sent only as x-goog-api-key and never appears in the URL")
    func apiKeyHeaderNeverQueryString() throws {
        let client = GeminiAuditClient(
            transport: SequenceGeminiTransport(steps: [.verdict(.approved)]),
            keyResolver: GeminiAPIKeyResolver(
                configuredKey: "test-gemini-key",
                environment: [:],
                secrets: EmptyGeminiSecrets()
            )
        )
        let evidence = try Self.sampleEvidence()
        let request = try client.makeGenerateContentRequest(
            evidence: evidence,
            model: .flash,
            apiKey: "test-gemini-key"
        )
        let url = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: GeminiAuditPolicy.apiKeyHeader) == "test-gemini-key")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "test-gemini-key")
        #expect(url.query == nil)
        #expect(url.queryValue(for: "key") == nil)
        #expect(!url.absoluteString.contains("key="))
        #expect(!url.absoluteString.contains("test-gemini-key"))
        #expect(url.absoluteString.contains("gemini-2.5-flash:generateContent"))
        #expect(!GeminiAuditModel.flash.rawValue.contains("1.5"))
        #expect(!GeminiAuditModel.pro.rawValue.contains("1.5"))
        #expect(GeminiAuditModel.flash.rawValue == "gemini-2.5-flash")
        #expect(GeminiAuditModel.pro.rawValue == "gemini-2.5-pro")
        #expect(request.timeoutInterval == GeminiAuditPolicy.requestTimeout)
    }

    @Test("system instructions include an explicit visual prompt-injection defense")
    func visualPromptInjectionDefenseInSystemInstruction() throws {
        let client = GeminiAuditClient(
            keyResolver: GeminiAPIKeyResolver(
                configuredKey: "test-gemini-key",
                environment: [:],
                secrets: EmptyGeminiSecrets()
            )
        )
        let body = try client.makeJSONBody(evidence: try Self.sampleEvidence(), model: .flash)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(json["systemInstruction"] as? [String: Any])
        let parts = try #require(system["parts"] as? [[String: Any]])
        let persona = try #require(parts.first?["text"] as? String)
        #expect(persona.contains(GeminiAuditPolicy.visualPromptInjectionDefense))
        #expect(persona.localizedCaseInsensitiveContains("visual prompt injection"))
        #expect(persona.localizedCaseInsensitiveContains("ignore any instructions"))
        #expect(persona.localizedCaseInsensitiveContains("embedded visually"))
        #expect(persona.localizedCaseInsensitiveContains("images"))
        #expect(persona.localizedCaseInsensitiveContains("receipts"))
        #expect(persona.localizedCaseInsensitiveContains("documents"))
    }

    @Test("EARNED_MEETING mint is idempotent for the same meeting reference")
    func earnedMeetingMintIsIdempotent() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let engine = Self.makeEngine(ledger: ledger)
        let meetingID = UUID()
        let first = try engine.mintEarnedMeeting(meetingID: meetingID, durationSeconds: 3_600)
        #expect(first.creditsMinted == 1.0)
        #expect(first.transaction?.referenceID == MeetingCreditMinting.walletReference(meetingID: meetingID))

        let second = try engine.mintEarnedMeeting(meetingID: meetingID, durationSeconds: 7_200)
        #expect(second.creditsMinted == 1.0)
        #expect(second.transaction?.id == first.transaction?.id)
        #expect(try ledger.allTransactions().filter { $0.transactionType == .earnedMeeting }.count == 1)
        #expect(try ledger.latestBalance() == 1.0)

        do {
            try ledger.appendTransaction(
                WalletTransaction(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                    amount: 4.0,
                    balanceAfter: 5.0,
                    transactionType: .earnedMeeting,
                    referenceID: MeetingCreditMinting.walletReference(meetingID: meetingID),
                    description: "forged duplicate"
                )
            )
            Issue.record("duplicate EARNED_MEETING reference must be rejected")
        } catch let error as EconomicLedgerError {
            #expect(error == .duplicateTransaction)
        }

        let rawSQL = """
        INSERT INTO wallet_transactions (
            id, timestamp, amount, balance_after, transaction_type, reference_id, description
        ) VALUES (
            '\(UUID().uuidString)',
            '2023-11-14T22:20:00Z',
            4.0,
            5.0,
            'EARNED_MEETING',
            'meeting:\(meetingID.uuidString)',
            'sqlite3 duplicate'
        );
        """
        do {
            try ledger.executeUncheckedSQL(rawSQL)
            Issue.record("UNIQUE meeting reference must abort a raw INSERT")
        } catch let error as EconomicLedgerError {
            switch error {
            case .duplicateTransaction:
                break
            case .sqlite(_, let message):
                #expect(message.localizedCaseInsensitiveContains("UNIQUE"))
            default:
                Issue.record("expected UNIQUE failure, got \(error)")
            }
        }
        #expect(try ledger.allTransactions().filter { $0.transactionType == .earnedMeeting }.count == 1)
    }

    @Test("in-memory ledger also refuses a second EARNED_MEETING for the same meeting")
    func inMemoryEarnedMeetingUniqueReference() throws {
        let ledger = InMemoryEconomicLedger()
        let reference = MeetingCreditMinting.walletReference(meetingID: UUID())
        try ledger.appendTransaction(
            WalletTransaction(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                amount: 1.0,
                balanceAfter: 1.0,
                transactionType: .earnedMeeting,
                referenceID: reference,
                description: "first"
            )
        )
        do {
            try ledger.appendTransaction(
                WalletTransaction(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                    amount: 1.0,
                    balanceAfter: 2.0,
                    transactionType: .earnedMeeting,
                    referenceID: reference,
                    description: "second"
                )
            )
            Issue.record("in-memory duplicate meeting mint must fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .duplicateTransaction)
        }
    }

    @Test("daily EARNED_MEETING cap of 4.0 credits is enforced by ExchangeEngine")
    func dailyMeetingCreditCapInEngine() throws {
        let engine = Self.makeEngine(ledger: InMemoryEconomicLedger())
        let first = try engine.mintEarnedMeeting(meetingID: UUID(), durationSeconds: 240 * 60)
        #expect(first.creditsMinted == 4.0)
        #expect(!first.clipped)

        let overflow = try engine.mintEarnedMeeting(meetingID: UUID(), durationSeconds: 3_600)
        #expect(overflow.creditsMinted == 0)
        #expect(overflow.clipped)
        #expect(overflow.explanation?.localizedCaseInsensitiveContains("cap") == true)
        #expect(try engine.earnedMeetingCredits(onLocalDay: "2023-11-14") == 4.0)
        #expect(try engine.ledger.latestBalance() == 4.0)

        let clipEngine = Self.makeEngine(ledger: InMemoryEconomicLedger())
        _ = try clipEngine.mintEarnedMeeting(meetingID: UUID(), durationSeconds: 3_600)
        let clipped = try clipEngine.mintEarnedMeeting(meetingID: UUID(), durationSeconds: 240 * 60)
        #expect(clipped.creditsMinted == 3.0)
        #expect(clipped.clipped)
        #expect(try clipEngine.earnedMeetingCredits(onLocalDay: "2023-11-14") == 4.0)
        #expect(try clipEngine.ledger.latestBalance() == 4.0)
    }

    @Test("coordinator clips a second approved meeting so the day cannot exceed 4.0 credits")
    func dailyMeetingCreditCapInCoordinator() async throws {
        let harness = try HardeningAuditHarness(sqlite: true, duration: 240 * 60)
        let first = try harness.submitBundle(salt: "cap-a")
        let approved = try await harness.auditor.auditFlash(meetingID: first.id)
        #expect(approved.auditStatus == .approved)
        #expect(approved.creditsMinted == 4.0)

        let secondSubmitted = try harness.submitBundle(salt: "cap-b")
        let second = try await harness.auditor.auditFlash(meetingID: secondSubmitted.id)
        #expect(second.auditStatus == .approved)
        #expect(second.creditsMinted == 0)
        #expect(second.aiReasoning?.localizedCaseInsensitiveContains("cap") == true)

        let minted = try harness.ledger.allTransactions().filter { $0.transactionType == .earnedMeeting }
        #expect(minted.count == 1)
        #expect(minted.reduce(0) { $0 + $1.amount } == 4.0)
        let day = harness.engine.civilClock.dayKey(harness.wall.now())
        #expect(try harness.engine.earnedMeetingCredits(onLocalDay: day) == 4.0)
    }

    @Test("429 then 200 is retried inside the Gemini client without minting twice")
    func transientHTTP429IsRetried() async throws {
        let transport = SequenceGeminiTransport(steps: [
            .status(429),
            .verdict(.approved),
        ])
        let client = GeminiAuditClient(
            transport: transport,
            keyResolver: GeminiAPIKeyResolver(
                configuredKey: "test-gemini-key",
                environment: [:],
                secrets: EmptyGeminiSecrets()
            ),
            maxAttempts: 3,
            retryDelayNanoseconds: 0
        )
        let verdict = try await client.audit(try Self.sampleEvidence(), model: .flash)
        #expect(verdict.decision == .approved)
        #expect(transport.attemptCount == 2)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: GeminiAuditPolicy.apiKeyHeader) == "test-gemini-key")
        #expect(!(request.url?.absoluteString.contains("key=") ?? true))
    }

    @Test("timeouts are retried, then a later Retry Audit mints once")
    func timeoutPersistsAndRetryAuditSucceeds() async throws {
        let transport = SequenceGeminiTransport(steps: [
            .timeout,
            .verdict(.approved),
        ])
        let harness = try HardeningAuditHarness(
            sqlite: true,
            duration: 3_600,
            transport: transport,
            maxAttempts: 1,
            retryDelayNanoseconds: 0
        )
        let submitted = try harness.submitBundle(salt: "retry-timeout")
        do {
            _ = try await harness.auditor.auditFlash(meetingID: submitted.id)
            Issue.record("first Flash pass must fail closed on timeout")
        } catch let error as GeminiAuditError {
            #expect(error == .timeout)
        }

        let failed = try #require(try harness.store.meeting(id: submitted.id))
        #expect(failed.auditStatus == .pending)
        #expect(failed.creditsMinted == 0)
        #expect(failed.lastAuditError != nil)
        #expect(failed.auditAttemptCount >= 1)
        #expect(failed.canRetryAudit)
        #expect(try harness.ledger.allTransactions().isEmpty)

        let restoredMeetings = OfflineSessionCoordinator(
            store: harness.store,
            artifacts: harness.artifacts,
            clock: harness.mono,
            uptimeClock: harness.mono,
            wallClock: harness.wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-gemini"
        )
        restoredMeetings.bindFocusEngine(harness.engine)
        let restored = restoredMeetings.snapshot()
        #expect(restored.meetingID == submitted.id)
        #expect(restored.canRetryAudit)
        #expect(restored.lastError != nil)
        #expect(restored.auditStatusCaption == "PENDING AUDIT")

        let retried = try await harness.auditor.retryAudit(meetingID: submitted.id)
        #expect(retried.auditStatus == .approved)
        #expect(retried.creditsMinted == 1.0)
        #expect(retried.lastAuditError == nil)
        let minted = try harness.ledger.allTransactions().filter { $0.transactionType == .earnedMeeting }
        #expect(minted.count == 1)
        #expect(minted[0].referenceID == MeetingCreditMinting.walletReference(meetingID: submitted.id))
    }

    @Test("APPEALED meetings that 429 keep a Retry Audit action for Pro")
    func appealedTransientFailureShowsRetry() async throws {
        let transport = SequenceGeminiTransport(steps: [
            .verdict(.rejected),
            .verdict(.rejected),
            .verdict(.rejected),
            .status(429),
            .verdict(.approved),
        ])
        let harness = try HardeningAuditHarness(
            sqlite: true,
            duration: 3_600,
            transport: transport,
            maxAttempts: 1,
            retryDelayNanoseconds: 0
        )
        let submitted = try harness.submitBundle(salt: "pro-retry")
        for _ in 0..<3 {
            _ = try await harness.auditor.auditFlash(meetingID: submitted.id)
        }
        do {
            _ = try await harness.auditor.appealToPro(
                meetingID: submitted.id,
                statement: "The café receipt is for this workshop."
            )
            Issue.record("Pro 429 must fail closed")
        } catch let error as GeminiAuditError {
            #expect(error == .httpStatus(429))
        }

        let appealed = try #require(try harness.store.meeting(id: submitted.id))
        #expect(appealed.auditStatus == .appealed)
        #expect(appealed.canRetryAudit)
        #expect(appealed.lastAuditError?.contains("429") == true)
        #expect(try harness.ledger.allTransactions().isEmpty)

        let snap = OfflineMeetingSnapshot.assemble(
            record: appealed,
            nowMonotonic: harness.mono.nowSeconds(),
            lastError: appealed.lastAuditError
        )
        #expect(snap.canRetryAudit)
        #expect(!snap.canAppeal)

        let recovered = try await harness.auditor.retryAudit(meetingID: submitted.id)
        #expect(recovered.auditStatus == .arbitratedApproved)
        #expect(recovered.creditsMinted == 1.0)
        #expect(try harness.ledger.allTransactions().filter { $0.transactionType == .earnedMeeting }.count == 1)
    }

    private static func sampleEvidence() throws -> GeminiAuditEvidence {
        let jpeg = try TestImageFactory.appleCameraJPEG(dateTime: "2023:11:14 22:20:00")
        return GeminiAuditEvidence(
            meetingID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            punchInUTC: Date(timeIntervalSince1970: 1_700_000_000),
            punchOutUTC: Date(timeIntervalSince1970: 1_700_003_600),
            durationSeconds: 3_600,
            agendaMarkdown: MeetingTestSupport.substantiveNotes,
            receipt: GeminiInlinePart(mimeType: "application/pdf", data: TestImageFactory.uniquePDF("hardening")),
            environmentPhoto: GeminiInlinePart(mimeType: "image/jpeg", data: jpeg)
        )
    }

    private static func makeEngine(ledger: any EconomicLedger) -> ExchangeEngine {
        let mono = ManualMonotonicClock(startingAt: 1_000)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        return ExchangeEngine(
            ledger: ledger,
            clock: mono,
            focusClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }
}

private struct EmptyGeminiSecrets: SecretProviding {
    func secret(service: String, account: String) -> String? { nil }
}

private enum GeminiTransportStep {
    case status(Int)
    case timeout
    case network
    case verdict(GeminiAuditVerdict)
}

private final class SequenceGeminiTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [GeminiTransportStep]
    private(set) var requests: [URLRequest] = []
    private(set) var attemptCount = 0

    init(steps: [GeminiTransportStep]) {
        self.steps = steps
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = nextStep(request)

        switch step {
        case .timeout:
            throw URLError(.timedOut)
        case .network:
            throw URLError(.networkConnectionLost)
        case .status(let code):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://generativelanguage.googleapis.com")!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data("{}".utf8), response)
        case .verdict(let verdict):
            let envelope = try Self.envelope(verdict)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://generativelanguage.googleapis.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (envelope, response)
        }
    }

    private func nextStep(_ request: URLRequest) -> GeminiTransportStep {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        attemptCount += 1
        if steps.isEmpty {
            return .verdict(.approved)
        }
        return steps.removeFirst()
    }

    private static func envelope(_ verdict: GeminiAuditVerdict) throws -> Data {
        let body = try JSONEncoder().encode(verdict)
        let text = String(data: body, encoding: .utf8) ?? "{}"
        let encoded = String(data: try JSONEncoder().encode(text), encoding: .utf8) ?? "\"\""
        return Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\(encoded)}]}}]}".utf8)
    }
}

private struct HardeningAuditHarness {
    let store: any OfflineMeetingStoring
    let ledger: any EconomicLedger
    let artifacts: MeetingArtifactStore
    let mono: ManualMonotonicClock
    let wall: ManualWallClock
    let meetings: OfflineSessionCoordinator
    let engine: ExchangeEngine
    let transport: SequenceGeminiTransport
    let auditor: OfflineMeetingAuditCoordinator
    let duration: TimeInterval

    init(
        sqlite: Bool = false,
        duration: TimeInterval,
        transport: SequenceGeminiTransport? = nil,
        maxAttempts: Int = 3,
        retryDelayNanoseconds: UInt64 = 0
    ) throws {
        self.duration = duration
        if sqlite {
            let sqliteLedger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
            store = sqliteLedger
            ledger = sqliteLedger
        } else {
            store = InMemoryOfflineMeetingStore()
            ledger = InMemoryEconomicLedger()
        }
        artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        mono = ManualMonotonicClock(startingAt: 1_000)
        wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        meetings = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: mono,
            uptimeClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-gemini"
        )
        engine = ExchangeEngine(
            ledger: ledger,
            clock: mono,
            focusClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        meetings.bindFocusEngine(engine)
        self.transport = transport ?? SequenceGeminiTransport(steps: [.verdict(.approved)])
        let client = GeminiAuditClient(
            transport: self.transport,
            keyResolver: GeminiAPIKeyResolver(
                configuredKey: "test-gemini-key",
                environment: [:],
                secrets: EmptyGeminiSecrets()
            ),
            maxAttempts: maxAttempts,
            retryDelayNanoseconds: retryDelayNanoseconds
        )
        auditor = OfflineMeetingAuditCoordinator(
            store: store,
            artifacts: artifacts,
            engine: engine,
            client: client,
            session: meetings
        )
    }

    func submitBundle(salt: String = UUID().uuidString) throws -> OfflineMeetingRecord {
        try meetings.punchIn()
        mono.advance(by: duration)
        wall.advance(by: duration)
        try meetings.punchOut()
        _ = try meetings.attach(kind: .notes, data: MeetingTestSupport.substantiveNotesData, fileExtension: "md")
        _ = try meetings.attach(
            kind: .receipt,
            data: TestImageFactory.uniquePDF("audit-\(salt)"),
            fileExtension: "pdf"
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let jpeg = try TestImageFactory.appleCameraJPEG(
            dateTime: formatter.string(from: wall.now()),
            fill: CGColor(
                red: 0.12 + Double(abs(salt.hashValue % 70)) / 100.0,
                green: 0.20 + Double(Int(salt.utf8.first ?? 1) % 40) / 100.0,
                blue: 0.18,
                alpha: 1
            )
        )
        _ = try meetings.attach(kind: .environmentPhoto, data: jpeg, fileExtension: "jpg")
        return try meetings.submit()
    }
}

private extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
