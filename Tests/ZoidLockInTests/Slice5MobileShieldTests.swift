import AppKit
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer

@Suite("Slice 5 mobile shield")
struct Slice5MobileShieldTests {
    @Test("serializes MobileShieldState with monotonic sequence and ISO-8601 timestamps")
    func serializesStateRoundTrip() throws {
        let expires = Date(timeIntervalSince1970: 1_700_000_180)
        let state = MobileShieldState(
            sessionActive: true,
            activePasses: [
                MobilePassRecord(
                    kind: .food,
                    expiresAtUtc: expires,
                    remainingDurationSeconds: 1_800
                ),
            ],
            sequenceNumber: 7,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 4,
            balanceCredits: 3.5
        )
        let data = try MobileShieldCoding.makeEncoder().encode(state)
        let decoded = try MobileShieldCoding.makeDecoder().decode(MobileShieldState.self, from: data)
        #expect(decoded == state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"sessionActive\":true"))
        #expect(json.contains("\"sequenceNumber\":7"))
        #expect(json.contains("2023-11-14T22:13:20"))
    }

    @Test("AES-GCM encrypts, decrypts, and rejects tampered ciphertext")
    func aesGCMRoundTripAndIntegrity() throws {
        let key = MobileShieldSecrets.randomKey()
        let state = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 2,
            balanceCredits: 1.5
        )
        let envelopeData = try EncryptedStateStore.encrypt(state, key: key)
        let envelopeJSON = try #require(String(data: envelopeData, encoding: .utf8))
        #expect(envelopeJSON.contains("AES-GCM"))
        #expect(!envelopeJSON.contains("sessionActive"))
        #expect(!envelopeJSON.contains("1.5"))

        let opened = try EncryptedStateStore.decrypt(envelopeData, key: key)
        #expect(opened == state)

        var envelope = try JSONDecoder().decode(EncryptedStateEnvelope.self, from: envelopeData)
        var combined = try #require(Data(base64Encoded: envelope.combined))
        combined[combined.count / 2] ^= 0xFF
        envelope.combined = combined.base64EncodedString()
        let tampered = try JSONEncoder().encode(envelope)
        do {
            _ = try EncryptedStateStore.decrypt(tampered, key: key)
            Issue.record("tampered ciphertext must fail integrity")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .integrityFailed)
        }

        let wrongKey = MobileShieldSecrets.randomKey()
        do {
            _ = try EncryptedStateStore.decrypt(envelopeData, key: wrongKey)
            Issue.record("wrong key must fail integrity")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .integrityFailed)
        }
    }

    @Test("sequence number is strictly authoritative over wall-clock timestamps")
    func lastWriteWinsWithSequenceTieBreak() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(1)
        let olderHighSeq = MobileShieldState(
            sessionActive: false,
            activePasses: [],
            sequenceNumber: 99,
            timestamp: t1,
            streakDays: 0,
            balanceCredits: 0
        )
        let newerLowSeq = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 2,
            timestamp: t2,
            streakDays: 1,
            balanceCredits: 1
        )
        #expect(olderHighSeq.wins(over: newerLowSeq))
        #expect(MobileShieldState.resolve(local: olderHighSeq, remote: newerLowSeq) == olderHighSeq)

        let tiedLow = MobileShieldState(
            sessionActive: false,
            activePasses: [],
            sequenceNumber: 4,
            timestamp: t1,
            streakDays: 0,
            balanceCredits: 0
        )
        let tiedHigh = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 5,
            timestamp: t1,
            streakDays: 1,
            balanceCredits: 2
        )
        #expect(tiedHigh.wins(over: tiedLow))
        #expect(MobileShieldState.resolve(local: tiedLow, remote: tiedHigh) == tiedHigh)
        #expect(MobileShieldState.resolve(candidates: [olderHighSeq, newerLowSeq, tiedHigh]) == olderHighSeq)
    }

    @Test("encrypted store persists to local fallback and refuses to clobber a newer snapshot")
    func storeLocalFallbackAndLWWPersist() throws {
        let directory = EncryptedStateStore.makeIsolatedDirectory()
        let store = EncryptedStateStore(
            fallbackDirectory: directory,
            ubiquityIdentifier: nil,
            key: MobileShieldSecrets.randomKey()
        )
        #expect(!store.usesUbiquitousContainer)
        #expect(store.fileURL.lastPathComponent == "state.json")

        let older = MobileShieldState(
            sessionActive: false,
            activePasses: [],
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 0,
            balanceCredits: 0
        )
        let newer = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 2,
            timestamp: Date(timeIntervalSince1970: 1_700_000_010),
            streakDays: 1,
            balanceCredits: 0.5
        )
        #expect(try store.persist(older) == older)
        #expect(try store.persist(newer) == newer)
        #expect(try store.persist(older) == newer)
        #expect(try store.load() == newer)

        let file = try Data(contentsOf: store.fileURL)
        let raw = try #require(String(data: file, encoding: .utf8))
        #expect(!raw.contains("sessionActive"))
        #expect(raw.contains("AES-GCM"))
    }

    @Test("ubiquitous container URL is preferred over the local fallback")
    func ubiquitousContainerPreferred() throws {
        let root = EncryptedStateStore.makeIsolatedDirectory()
        let iCloud = root.appendingPathComponent(
            ZoidLockInIdentity.ubiquitousDirectoryName,
            isDirectory: true
        )
        let fallback = root.appendingPathComponent("local-fallback", isDirectory: true)
        let store = EncryptedStateStore(
            fallbackDirectory: fallback,
            ubiquityIdentifier: ZoidLockInIdentity.ubiquityContainerIdentifier,
            ubiquity: FixedUbiquityResolver(url: iCloud),
            key: MobileShieldSecrets.randomKey()
        )
        #expect(store.usesUbiquitousContainer)
        #expect(store.directoryURL.path.contains(ZoidLockInIdentity.ubiquitousDirectoryName))
        #expect(store.directoryURL.path.contains("Library"))
        #expect(store.directoryURL.path.contains("mobile-shield"))
        #expect(!store.directoryURL.path.contains("/Documents/"))
        #expect(ZoidLockInIdentity.ubiquityContainerIdentifier == "iCloud.com.mavoid.zoidlockin")

        let state = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 0,
            balanceCredits: 0
        )
        _ = try store.persist(state)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.appendingPathComponent("state.json").path))
    }

    @Test("push relay payload is a silent APNs trigger for the Lock In shortcut")
    func pushRelayPayloadAndEndpoint() throws {
        let state = MobileShieldState(
            sessionActive: true,
            activePasses: [
                MobilePassRecord(
                    kind: .phone,
                    expiresAtUtc: Date(timeIntervalSince1970: 1_700_003_600),
                    remainingDurationSeconds: 3_600
                ),
            ],
            sequenceNumber: 11,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 3,
            balanceCredits: 2
        )
        let payload = PushRelayPayload.make(
            command: .passUnlocked,
            state: state,
            targetPassKind: .phone,
            durationSeconds: 3_600
        )
        #expect(payload.command == .passUnlocked)
        #expect(payload.command.rawValue == "pass_unlocked")
        #expect(payload.targetPassKind == .phone)
        #expect(payload.durationSeconds == 3_600)
        #expect(payload.expiresAtUtc == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(payload.localRelockDurationSeconds == 3_600)
        #expect(payload.sequenceNumber == 11)
        #expect(payload.isSilent)
        #expect(payload.aps.contentAvailable == 1)
        #expect(payload.focusMode == "Lock In")
        #expect(payload.shortcutName == "Lock In")

        let endpoint = URL(string: "https://relay.test/v1/push")!
        let signedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let client = PushRelayClient(
            configuration: PushRelayConfiguration(
                endpoint: endpoint,
                enabled: true,
                hmacSecret: testRelayHMACSecret
            )
        )
        let request = try client.makeURLRequest(payload: payload, now: signedAt)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.url?.absoluteString.hasSuffix("/v1/push") == true)
        #expect(request.timeoutInterval == 3)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: PushRelayAuthenticator.timestampHeader) == "1700000000")
        #expect(request.value(forHTTPHeaderField: PushRelayAuthenticator.signatureHeader) != nil)

        let body = try #require(request.httpBody)
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("\"command\":\"pass_unlocked\""))
        #expect(json.contains("\"expiresAtUtc\""))
        #expect(json.contains("\"localRelockDurationSeconds\":3600"))
        #expect(json.contains("\"content-available\":1"))
        #expect(json.contains("Lock In"))
        #expect(!json.contains("alert"))
        #expect(!json.contains("sound"))

        let decoded = try MobileShieldCoding.makeDecoder().decode(PushRelayPayload.self, from: body)
        #expect(decoded.command == .passUnlocked)
        #expect(decoded.aps.contentAvailable == 1)
        #expect(PushRelayCommand.engageLockdown.rawValue == "engage_lockdown")
        #expect(PushRelayCommand.releaseLockdown.rawValue == "release_lockdown")

        let emergencyState = MobileShieldState(
            sessionActive: false,
            activePasses: [
                MobilePassRecord(
                    kind: .emergency,
                    expiresAtUtc: Date(timeIntervalSince1970: 1_700_001_800),
                    remainingDurationSeconds: 1_800
                ),
            ],
            sequenceNumber: 12,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 0,
            balanceCredits: 0
        )
        #expect(
            MobileShieldCoordinator.command(for: .passRedeemed(kind: .emergency, durationSeconds: 1_800), state: emergencyState)
                == .releaseLockdown
        )
    }

    @Test("push relay retries then fails silent without throwing")
    func pushRelayRetryTimeoutFailSilent() async {
        let hanging = HangingHTTPTransport()
        let client = PushRelayClient(
            configuration: PushRelayConfiguration(
                endpoint: URL(string: "https://relay.test/v1/push")!,
                enabled: true,
                timeoutInterval: 0.05,
                maxAttempts: 2,
                retryDelayNanoseconds: 0,
                hmacSecret: testRelayHMACSecret
            ),
            transport: hanging
        )
        let payload = PushRelayPayload(
            command: .engageLockdown,
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let outcome = await client.dispatch(payload)
        #expect(outcome == .failed)
        #expect(hanging.attempts >= 1)

        let skipped = await PushRelayClient(
            configuration: PushRelayConfiguration(enabled: false),
            transport: hanging
        ).dispatch(payload)
        #expect(skipped == .skipped)

        let flaky = FlakyHTTPTransport(failuresBeforeSuccess: 2, statusCode: 503)
        let retrying = PushRelayClient(
            configuration: PushRelayConfiguration(
                endpoint: URL(string: "https://relay.test/v1/push")!,
                enabled: true,
                timeoutInterval: 1,
                maxAttempts: 3,
                retryDelayNanoseconds: 0,
                hmacSecret: testRelayHMACSecret
            ),
            transport: flaky
        )
        #expect(await retrying.dispatch(payload) == .sent)
        #expect(flaky.attempts == 3)
    }

    @Test("focus start writes encrypted state and dispatches engage_lockdown")
    func endToEndFocusStartSync() async throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        let (store, relay, transport, coordinator) = makeShield()
        try harness.engine.startFocus()
        let publication = await coordinator.sync(
            engine: harness.engine,
            now: harness.wall.now(),
            event: .focusStarted
        )
        #expect(publication.state.sessionActive)
        #expect(publication.state.sequenceNumber == 1)
        #expect(publication.state.streakDays == 0)
        #expect(publication.command == .engageLockdown)
        #expect(publication.status.caption == "SHIELD: SYNCED · FOCUS ACTIVE")
        #expect(try store.load()?.sessionActive == true)
        #expect(try store.load()?.sequenceNumber == 1)

        let payload = try #require(transport.payloads.last)
        #expect(payload.command == .engageLockdown)
        #expect(payload.sequenceNumber == 1)
        #expect(payload.aps.contentAvailable == 1)
        #expect(payload.focusMode == "Lock In")
        #expect(relay.configuration.enabled)
    }

    @Test("ticks increment sequence monotonically without spamming push")
    func monotonicSequenceOnTicks() async throws {
        let harness = EngineHarness(hour: 9, minute: 0)
        let (_, _, transport, coordinator) = makeShield()
        try harness.engine.startFocus()
        _ = await coordinator.sync(
            engine: harness.engine,
            now: harness.wall.now(),
            event: .focusStarted
        )
        harness.advance(1)
        let tick = await coordinator.sync(
            engine: harness.engine,
            now: harness.wall.now(),
            event: .focusTick
        )
        #expect(tick.state.sequenceNumber == 2)
        #expect(tick.pushOutcome == .skipped)
        #expect(tick.command == nil)
        #expect(transport.payloads.count == 1)

        let completed = try harness.engine.completeFocus()
        #expect(completed.state == .completed)
        let done = await coordinator.sync(
            engine: harness.engine,
            now: harness.wall.now(),
            event: .focusCompleted
        )
        #expect(done.state.sessionActive == false)
        #expect(done.state.sequenceNumber == 3)
        #expect(done.command == .engageLockdown)
        #expect(transport.payloads.count == 2)
        #expect(transport.payloads.last?.command == .engageLockdown)
    }

    @Test("food and phone redemptions sync pass_unlocked and expiry re-engages lockdown")
    func endToEndPassRedeemAndExpiry() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 6.0)
        let daemon = EnforcementDaemon(
            clock: harness.mono,
            wallClock: harness.wall,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-shield",
            voucherVerifier: AmenityVoucherVerifier(),
            civilClock: harness.civil
        )
        let (store, _, transport, shield) = makeShield()
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono,
            shield: shield
        )

        let food = try await coordinator.purchase(.food)
        #expect(food.cost == 2.5)
        let afterFood = shield.currentState
        #expect(afterFood.hasMobilePass)
        #expect(afterFood.activePasses.contains { $0.kind == .food && $0.remainingDurationSeconds == 1_800 })
        #expect(transport.payloads.last?.command == .passUnlocked)
        #expect(transport.payloads.last?.targetPassKind == .food)
        #expect(transport.payloads.last?.durationSeconds == 1_800)
        #expect(transport.payloads.last?.localRelockDurationSeconds == 1_800)
        #expect(transport.payloads.last?.expiresAtUtc != nil)

        try await coordinator.purchase(.phone)
        let afterPhone = shield.currentState
        #expect(Set(afterPhone.mobilePassKinds) == [.food, .phone])
        #expect(transport.payloads.last?.command == .passUnlocked)
        #expect(transport.payloads.last?.targetPassKind == .phone)
        #expect(try store.load()?.balanceCredits == 2.0)

        let status = try await daemon.queryStatus()
        let snapshot = try coordinator.snapshot(status: status)
        #expect(snapshot.mobileShieldCaption.contains("SHIELD:"))
        #expect(snapshot.mobileShield.passActive)

        harness.advance(1_801)
        let expiredStatus = try await daemon.queryStatus()
        #expect(expiredStatus.activePasses.contains { $0.kind == .food } == false)
        let expiry = await shield.publish(
            ticker: try harness.engine.snapshot(),
            status: expiredStatus,
            now: harness.wall.now(),
            event: .focusTick
        )
        #expect(expiry.command == .passUnlocked || expiry.command == .engageLockdown)
        #expect(expiry.state.activePasses.contains { $0.kind == .food } == false)
        #expect(expiry.state.activePasses.contains { $0.kind == .phone })
        #expect(transport.payloads.last?.command == .passUnlocked)
        #expect(transport.payloads.last?.targetPassKind == .phone)

        harness.advance(3_600)
        let locked = await shield.publish(
            ticker: try harness.engine.snapshot(),
            status: try await daemon.queryStatus(),
            now: harness.wall.now(),
            event: .focusTick
        )
        #expect(locked.state.hasMobilePass == false)
        #expect(locked.command == .engageLockdown)
        #expect(transport.payloads.last?.command == .engageLockdown)
    }

    @Test("marketplace captions match SYNCED focus and LOCAL ONLY unconfigured copy")
    func shieldCaptions() {
        #expect(MarketplaceSnapshot.mobileShieldProof.mobileShieldCaption == "SHIELD: SYNCED · FOCUS ACTIVE")
        #expect(MarketplaceSnapshot.proof.mobileShieldCaption == "SHIELD: LOCAL ONLY")

        let idleTicker = MenuBarTickerSnapshot(
            walletBalance: 4.0,
            spendableBalance: 4.0,
            focusState: nil,
            focusElapsedSeconds: 0,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1.0,
            currentStreak: 3,
            highestStreak: 7,
            lifetimeSurplus: 10,
            isFridayRest: false,
            isCurfew: false,
            isClockTampered: false,
            localDayKey: "2026-09-13",
            weekdayCaption: "Sunday",
            dayStateCaption: "Idle"
        )
        let passOnly = MarketplaceSnapshot.assemble(
            ticker: idleTicker,
            status: EnforcementStatus(
                mode: .hard,
                isLockedDown: false,
                activePassKind: .phone,
                remainingPassSeconds: 1_200,
                activePasses: [ActivePassStatus(kind: .phone, remainingSeconds: 1_200)]
            ),
            mobileShield: MobileShieldStatus(
                link: .synced,
                sessionActive: false,
                passActive: true,
                relayConfigured: true
            )
        )
        #expect(passOnly.mobileShieldCaption == "SHIELD: SYNCED · PASS ACTIVE")

        let idle = MarketplaceSnapshot.assemble(ticker: idleTicker)
        #expect(idle.mobileShieldCaption == "SHIELD: LOCAL ONLY")
        #expect(
            MobileShieldStatus(
                link: .notConfigured,
                sessionActive: false,
                passActive: false,
                relayConfigured: false
            ).caption == "SHIELD: NOT CONFIGURED"
        )
    }

    @Test("failed push does not throw or block a marketplace purchase")
    func failSilentDoesNotBlockPurchase() async throws {
        let harness = EngineHarness(hour: 11, minute: 0)
        try seed(harness, credits: 6.0)
        let daemon = EnforcementDaemon(
            clock: harness.mono,
            wallClock: harness.wall,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-fail-silent",
            voucherVerifier: AmenityVoucherVerifier(),
            civilClock: harness.civil
        )
        let store = EncryptedStateStore(
            fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
            ubiquityIdentifier: nil,
            key: MobileShieldSecrets.randomKey()
        )
        let shield = MobileShieldCoordinator(
            store: store,
            relay: PushRelayClient(
                configuration: PushRelayConfiguration(
                    endpoint: URL(string: "https://relay.test/v1/push")!,
                    enabled: true,
                    timeoutInterval: 0.05,
                    maxAttempts: 1,
                    retryDelayNanoseconds: 0,
                    hmacSecret: testRelayHMACSecret
                ),
                transport: HangingHTTPTransport()
            )
        )
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono,
            shield: shield
        )
        let purchase = try await coordinator.purchase(.food)
        #expect(purchase.voucher?.isVerified == true)
        #expect(harness.engine.walletBalance == 3.5)
        #expect(try await daemon.queryStatus().activePassKind == .food)
        #expect(shield.currentState.hasMobilePass)
        #expect(shield.currentStatus.caption.contains("PASS ACTIVE") || shield.currentStatus.caption.contains("FOCUS"))
    }

    @MainActor
    @Test("renders a high-resolution SUMI-E mobile shield proof PNG")
    func mobileShieldProofPNG() throws {
        let url = MobileShieldProofRenderer.defaultProofURL
        try MobileShieldProofRenderer.renderPNG(snapshot: .mobileShieldProof, to: url, scale: 3)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        #expect(data.count > 12_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 440)
        #expect((image?.size.height ?? 0) >= 700)

        #expect(MarketplaceSnapshot.mobileShieldProof.mobileShieldCaption == "SHIELD: SYNCED · FOCUS ACTIVE")
        #expect(MarketplaceSnapshot.mobileShieldProof.activeItems.count == 2)
        #expect(MarketplaceSnapshot.mobileShieldProof.mobileShield.sessionActive)
        #expect(MarketplaceSnapshot.mobileShieldProof.mobileShield.passActive)
    }
}

private func seed(_ harness: EngineHarness, credits: Double) throws {
    try harness.ledger.appendTransaction(
        WalletTransaction(
            timestamp: harness.wall.now(),
            amount: credits,
            balanceAfter: credits,
            transactionType: .mint,
            description: "seed"
        )
    )
}

private let testRelayHMACSecret = "zoid-test-relay-hmac"
private let testRelayEndpoint = URL(string: "https://relay.test/v1/push")!

private func makeShield() -> (
    EncryptedStateStore,
    PushRelayClient,
    RecordingPushTransport,
    MobileShieldCoordinator
) {
    let store = EncryptedStateStore(
        fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
        ubiquityIdentifier: nil,
        keyProvider: InMemoryMobileShieldKeyProvider()
    )
    let transport = RecordingPushTransport()
    let relay = PushRelayClient(
        configuration: PushRelayConfiguration(
            endpoint: testRelayEndpoint,
            enabled: true,
            timeoutInterval: 1,
            maxAttempts: 1,
            retryDelayNanoseconds: 0,
            hmacSecret: testRelayHMACSecret
        ),
        transport: transport
    )
    let coordinator = MobileShieldCoordinator(store: store, relay: relay)
    return (store, relay, transport, coordinator)
}

private struct FixedUbiquityResolver: UbiquityContainerResolving {
    var url: URL?

    func url(forUbiquityContainerIdentifier identifier: String?) -> URL? {
        url
    }
}

private final class RecordingPushTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var statusCode: Int = 200

    var payloads: [PushRelayPayload] {
        recordedRequests().compactMap { request in
            guard let body = request.httpBody else { return nil }
            return try? MobileShieldCoding.makeDecoder().decode(PushRelayPayload.self, from: body)
        }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        remember(request)
        let response = HTTPURLResponse(
            url: request.url ?? testRelayEndpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }

    private func remember(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    private func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class HangingHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var attempts = 0

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bumpAttempt()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let response = HTTPURLResponse(
            url: request.url ?? testRelayEndpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }

    private func bumpAttempt() {
        lock.lock()
        attempts += 1
        lock.unlock()
    }
}

private final class FlakyHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private let failureStatus: Int
    private(set) var attempts = 0

    init(failuresBeforeSuccess: Int, statusCode: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failureStatus = statusCode
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let attempt = nextAttempt()
        let code = attempt <= failuresBeforeSuccess ? failureStatus : 200
        let response = HTTPURLResponse(
            url: request.url ?? testRelayEndpoint,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }

    private func nextAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        return attempts
    }
}
