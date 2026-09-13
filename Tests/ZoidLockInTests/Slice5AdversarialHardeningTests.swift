import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer

@Suite("Slice 5 adversarial hardening")
struct Slice5AdversarialHardeningTests {
    @Test("Keychain provider persists a random 256-bit key and rejects the Team ID KDF")
    func keychainKeyIsRandomAndRejectsTeamIDKDF() throws {
        let store = InMemoryKeychainStore()
        let account = "com.mavoid.zoidlockin.mobile-shield.key.\(UUID().uuidString)"
        let provider = KeychainMobileShieldKeyProvider(
            store: store,
            service: "com.mavoid.zoidlockin.mobile-shield.test",
            account: account
        )

        let first = try provider.loadOrCreate()
        #expect(MobileShieldSecrets.rawBytes(of: first).count == 32)
        #expect(!MobileShieldSecrets.isPublicTeamIdentifierKDF(first, teamID: "TEAMID"))
        #expect(!MobileShieldSecrets.isPublicTeamIdentifierKDF(first, teamID: "TESTTEAMID"))

        let second = try provider.loadOrCreate()
        #expect(MobileShieldSecrets.constantTimeEquals(first, second))

        let forbidden = MobileShieldSecrets.publicTeamIdentifierDerivedKey(teamID: "TEAMID")
        try store.setData(
            MobileShieldSecrets.rawBytes(of: forbidden),
            service: provider.service,
            account: provider.account
        )
        let rotated = try provider.loadOrCreate()
        #expect(!MobileShieldSecrets.isPublicTeamIdentifierKDF(rotated, teamID: "TEAMID"))
        #expect(!MobileShieldSecrets.constantTimeEquals(rotated, forbidden))

        let productionStore = EncryptedStateStore(
            fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
            ubiquityIdentifier: nil
        )
        #expect(!MobileShieldSecrets.isPublicTeamIdentifierKDF(productionStore.key, teamID: "TEAMID"))
        #expect(productionStore.directoryURL.lastPathComponent == EncryptedStateStore.isolatedFolderName)
        #expect(!productionStore.directoryURL.path.contains("/Documents/"))

        do {
            _ = try MobileShieldSecrets.validatedKey(
                from: MobileShieldSecrets.rawBytes(of: forbidden)
            )
            Issue.record("Team ID KDF must be rejected as an unauthenticated key")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .unauthenticatedKey)
        }

        do {
            _ = try MobileShieldSecrets.validatedKey(from: Data(repeating: 0, count: 8))
            Issue.record("truncated key material must be rejected")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .unauthenticatedKey)
        }
    }

    @Test("HMAC signature verifies and timestamps outside 300s are rejected")
    func webhookAuthenticationAndReplayWindow() throws {
        let payload = PushRelayPayload(
            command: .passUnlocked,
            targetPassKind: .food,
            durationSeconds: 1_800,
            expiresAtUtc: Date(timeIntervalSince1970: 1_700_001_800),
            localRelockDurationSeconds: 1_800,
            sequenceNumber: 4,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let secret = "relay-hmac-secret"
        let signedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try PushRelayClient.makeURLRequest(
            payload: payload,
            configuration: PushRelayConfiguration(
                endpoint: URL(string: "https://relay.test/v1/push")!,
                enabled: true,
                hmacSecret: secret
            ),
            now: signedAt
        )
        let body = try #require(request.httpBody)
        let timestamp = try #require(request.value(forHTTPHeaderField: PushRelayAuthenticator.timestampHeader))
        let signature = try #require(request.value(forHTTPHeaderField: PushRelayAuthenticator.signatureHeader))

        try PushRelayAuthenticator.verify(
            timestampHeader: timestamp,
            signatureHeader: signature,
            authorizationHeader: nil,
            payload: body,
            hmacSecret: secret,
            expectedBearer: nil,
            now: signedAt
        )

        do {
            try PushRelayAuthenticator.verify(
                timestampHeader: timestamp,
                signatureHeader: "deadbeef",
                authorizationHeader: nil,
                payload: body,
                hmacSecret: secret,
                expectedBearer: nil,
                now: signedAt
            )
            Issue.record("forged HMAC must be rejected")
        } catch let error as PushRelayError {
            #expect(error == .unauthenticated)
        }

        do {
            try PushRelayAuthenticator.verify(
                timestampHeader: timestamp,
                signatureHeader: signature,
                authorizationHeader: nil,
                payload: body,
                hmacSecret: secret,
                expectedBearer: nil,
                now: signedAt.addingTimeInterval(PushRelayAuthenticator.replayWindowSeconds + 1)
            )
            Issue.record("replay outside 300s must be rejected")
        } catch let error as PushRelayError {
            #expect(error == .replayRejected)
        }

        try PushRelayAuthenticator.verify(
            timestampHeader: timestamp,
            signatureHeader: signature,
            authorizationHeader: nil,
            payload: body,
            hmacSecret: secret,
            expectedBearer: nil,
            now: signedAt.addingTimeInterval(PushRelayAuthenticator.replayWindowSeconds)
        )

        let bearerRequest = try PushRelayClient.makeURLRequest(
            payload: payload,
            configuration: PushRelayConfiguration(
                endpoint: URL(string: "https://relay.test/v1/push")!,
                enabled: true,
                apiKey: "relay-bearer-token"
            ),
            now: signedAt
        )
        try PushRelayAuthenticator.verify(
            timestampHeader: bearerRequest.value(forHTTPHeaderField: PushRelayAuthenticator.timestampHeader),
            signatureHeader: bearerRequest.value(forHTTPHeaderField: PushRelayAuthenticator.signatureHeader),
            authorizationHeader: bearerRequest.value(forHTTPHeaderField: "Authorization"),
            payload: try #require(bearerRequest.httpBody),
            hmacSecret: nil,
            expectedBearer: "relay-bearer-token",
            now: signedAt
        )

        let unconfigured = PushRelayConfiguration.resolve(
            environment: [:],
            secrets: EmptySecrets()
        )
        #expect(unconfigured.endpoint == nil)
        #expect(!unconfigured.enabled)
        #expect(!unconfigured.isConfigured)

        let urlWithoutSecret = PushRelayConfiguration.resolve(
            explicitEndpoint: URL(string: "https://relay.test/v1/push")!,
            environment: [:],
            secrets: EmptySecrets()
        )
        #expect(!urlWithoutSecret.enabled)

        let armed = PushRelayConfiguration.resolve(
            environment: [
                PushRelayConfiguration.defaultEnvironmentVariable: "https://relay.test/v1/push",
                PushRelayConfiguration.hmacSecretEnvironmentVariable: secret,
            ],
            secrets: EmptySecrets()
        )
        #expect(armed.enabled)
        #expect(armed.endpoint?.host == "relay.test")

        do {
            _ = try PushRelayClient.makeURLRequest(
                payload: payload,
                configuration: PushRelayConfiguration(
                    endpoint: URL(string: "https://relay.test/v1/push")!,
                    enabled: true
                ),
                now: signedAt
            )
            Issue.record("unauthenticated relay requests must not be constructed")
        } catch let error as PushRelayError {
            #expect(error == .unauthenticated)
        }
    }

    @Test("lower sequence with a future timestamp cannot clobber a newer sequence")
    func sequenceFirstRejectsFutureDatedLowerSequence() throws {
        let directory = EncryptedStateStore.makeIsolatedDirectory()
        let highWater = InMemorySequenceHighWater()
        let store = EncryptedStateStore(
            fallbackDirectory: directory,
            ubiquityIdentifier: nil,
            keyProvider: InMemoryMobileShieldKeyProvider(),
            highWater: highWater
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let poisonPasses = [
            MobilePassRecord(
                kind: .food,
                expiresAtUtc: Date(timeIntervalSince1970: 4_102_444_800),
                remainingDurationSeconds: 86_400
            ),
        ]
        let honest = MobileShieldState(
            sessionActive: false,
            activePasses: [],
            sequenceNumber: 10,
            timestamp: now,
            streakDays: 1,
            balanceCredits: 1
        )
        #expect(try store.persist(honest, now: now) == honest)

        let inWindowPoison = MobileShieldState(
            sessionActive: false,
            activePasses: poisonPasses,
            sequenceNumber: 3,
            timestamp: now.addingTimeInterval(10),
            streakDays: 0,
            balanceCredits: 0
        )
        #expect(!inWindowPoison.wins(over: honest))
        #expect(try store.persist(inWindowPoison, now: now) == honest)

        let poison = MobileShieldState(
            sessionActive: false,
            activePasses: poisonPasses,
            sequenceNumber: 3,
            timestamp: Date(timeIntervalSince1970: 4_102_444_800),
            streakDays: 0,
            balanceCredits: 0
        )
        #expect(!poison.wins(over: honest))
        do {
            _ = try store.persist(poison, now: now)
            Issue.record("future-dated poison must not be accepted")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .clockRejected)
        }
        #expect(try store.load() == honest)
        #expect(try store.load()?.hasMobilePass == false)

        try FileManager.default.removeItem(at: store.fileURL)
        do {
            _ = try store.persist(
                MobileShieldState(
                    sessionActive: false,
                    activePasses: poison.activePasses,
                    sequenceNumber: 10,
                    timestamp: now,
                    streakDays: 0,
                    balanceCredits: 0
                ),
                now: now
            )
            Issue.record("delete-then-replay of the high-water sequence must fail")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .staleSequence)
        }
        #expect(try store.load() == nil)
    }

    @Test("TimeTravelGuard refuses shield writes after clock tamper")
    func timeTravelGuardBlocksStateWrites() async throws {
        let timeTravel = TimeTravelGuard()
        _ = timeTravel.observe(wall: Date(timeIntervalSince1970: 1_000), monotonic: 0)
        _ = timeTravel.observe(wall: Date(timeIntervalSince1970: 20_000), monotonic: 1)
        #expect(timeTravel.isTampered)

        let store = EncryptedStateStore(
            fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
            ubiquityIdentifier: nil,
            keyProvider: InMemoryMobileShieldKeyProvider(),
            timeTravel: timeTravel
        )
        let state = MobileShieldState(
            sessionActive: true,
            activePasses: [],
            sequenceNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 0,
            balanceCredits: 0
        )
        do {
            _ = try store.persist(state, now: Date(timeIntervalSince1970: 1_700_000_000))
            Issue.record("tampered clock must refuse persist")
        } catch let error as EncryptedStateStoreError {
            #expect(error == .clockRejected)
        }

        let ticker = MenuBarTickerSnapshot(
            walletBalance: 1,
            spendableBalance: 1,
            focusState: .active,
            focusElapsedSeconds: 10,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1,
            currentStreak: 0,
            highestStreak: 0,
            lifetimeSurplus: 0,
            isFridayRest: false,
            isCurfew: false,
            isClockTampered: true,
            localDayKey: "2026-09-13",
            weekdayCaption: "Sunday",
            dayStateCaption: "Tamper"
        )
        let coordinator = MobileShieldCoordinator(
            store: EncryptedStateStore(
                fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
                ubiquityIdentifier: nil
            ),
            relay: PushRelayClient(
                configuration: PushRelayConfiguration(
                    endpoint: URL(string: "https://relay.test/v1/push")!,
                    enabled: true,
                    hmacSecret: "test-hmac"
                )
            )
        )
        let publication = await coordinator.publish(
            ticker: ticker,
            status: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            event: .focusTick
        )
        #expect(publication.pushOutcome == .skipped)
        #expect(publication.command == nil)
        #expect(publication.state.sequenceNumber == 0)
    }

    @Test("pass_unlocked payloads carry absolute expiry and local relock duration")
    func explicitExpirationPayloadFormatting() throws {
        let expires = Date(timeIntervalSince1970: 1_700_001_800)
        let state = MobileShieldState(
            sessionActive: false,
            activePasses: [
                MobilePassRecord(
                    kind: .phone,
                    expiresAtUtc: expires,
                    remainingDurationSeconds: 1_800,
                    localRelockDurationSeconds: 1_800
                ),
            ],
            sequenceNumber: 8,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streakDays: 0,
            balanceCredits: 2
        )
        let payload = PushRelayPayload.make(
            command: .passUnlocked,
            state: state,
            targetPassKind: .phone,
            durationSeconds: 1_800,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(payload.expiresAtUtc == expires)
        #expect(payload.localRelockDurationSeconds == 1_800)
        let json = try #require(
            String(data: MobileShieldCoding.makeEncoder().encode(payload), encoding: .utf8)
        )
        #expect(json.contains("\"expiresAtUtc\":\"2023-11-14T22:43:20"))
        #expect(json.contains("\"localRelockDurationSeconds\":1800"))

        let expired = MobileShieldState(
            sessionActive: false,
            activePasses: [],
            sequenceNumber: 9,
            timestamp: Date(timeIntervalSince1970: 1_700_001_800),
            streakDays: 0,
            balanceCredits: 2
        )
        #expect(
            MobileShieldCoordinator.command(for: .passExpired(kind: .phone), state: expired)
                == .engageLockdown
        )
        let lockdown = PushRelayPayload.make(
            command: .engageLockdown,
            state: expired,
            now: Date(timeIntervalSince1970: 1_700_001_800)
        )
        #expect(lockdown.localRelockDurationSeconds == 0)
        #expect(lockdown.expiresAtUtc == Date(timeIntervalSince1970: 1_700_001_800))
    }

    @Test("UI reports LOCAL ONLY / NOT CONFIGURED until the relay is actually armed")
    func truthfulShieldStatusForConfiguredAndUnconfiguredRelay() async {
        let unconfigured = MobileShieldCoordinator(
            store: EncryptedStateStore(
                fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
                ubiquityIdentifier: nil
            ),
            relay: PushRelayClient(configuration: PushRelayConfiguration())
        )
        #expect(unconfigured.currentStatus.caption == "SHIELD: LOCAL ONLY")
        #expect(!unconfigured.currentStatus.relayConfigured)

        let idleTicker = MenuBarTickerSnapshot(
            walletBalance: 4,
            spendableBalance: 4,
            focusState: .active,
            focusElapsedSeconds: 12,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1,
            currentStreak: 1,
            highestStreak: 1,
            lifetimeSurplus: 0,
            isFridayRest: false,
            isCurfew: false,
            isClockTampered: false,
            localDayKey: "2026-09-13",
            weekdayCaption: "Sunday",
            dayStateCaption: "Focus"
        )
        let localPublication = await unconfigured.publish(
            ticker: idleTicker,
            status: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            event: .focusStarted
        )
        #expect(localPublication.status.caption == "SHIELD: LOCAL ONLY")
        #expect(
            MarketplaceSnapshot.assemble(ticker: idleTicker).mobileShieldCaption
                == "SHIELD: LOCAL ONLY"
        )
        #expect(
            MobileShieldStatus(
                link: .notConfigured,
                sessionActive: true,
                passActive: false
            ).caption == "SHIELD: NOT CONFIGURED"
        )

        let configured = MobileShieldCoordinator(
            store: EncryptedStateStore(
                fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
                ubiquityIdentifier: nil
            ),
            relay: PushRelayClient(
                configuration: PushRelayConfiguration(
                    endpoint: URL(string: "https://relay.test/v1/push")!,
                    enabled: true,
                    hmacSecret: "ui-hmac"
                ),
                transport: NullPushTransport()
            )
        )
        let syncedFocus = await configured.publish(
            ticker: idleTicker,
            status: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            event: .focusStarted
        )
        #expect(syncedFocus.status.caption == "SHIELD: SYNCED · FOCUS ACTIVE")

        let passTicker = MenuBarTickerSnapshot(
            walletBalance: 4,
            spendableBalance: 4,
            focusState: nil,
            focusElapsedSeconds: 0,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1,
            currentStreak: 1,
            highestStreak: 1,
            lifetimeSurplus: 0,
            isFridayRest: false,
            isCurfew: false,
            isClockTampered: false,
            localDayKey: "2026-09-13",
            weekdayCaption: "Sunday",
            dayStateCaption: "Idle"
        )
        let syncedPass = await configured.publish(
            ticker: passTicker,
            status: EnforcementStatus(
                mode: .hard,
                isLockedDown: false,
                activePassKind: .phone,
                remainingPassSeconds: 1_200,
                activePasses: [ActivePassStatus(kind: .phone, remainingSeconds: 1_200)]
            ),
            now: Date(timeIntervalSince1970: 1_700_000_000),
            event: .passRedeemed(kind: .phone, durationSeconds: 1_200)
        )
        #expect(syncedPass.status.caption == "SHIELD: SYNCED · PASS ACTIVE")
        #expect(MarketplaceSnapshot.mobileShieldProof.mobileShieldCaption == "SHIELD: SYNCED · FOCUS ACTIVE")
    }

    @Test("serialized publish keeps a live pass when a tick races a purchase")
    func concurrentTickAndPurchasePreservePass() async throws {
        let store = EncryptedStateStore(
            fallbackDirectory: EncryptedStateStore.makeIsolatedDirectory(),
            ubiquityIdentifier: nil
        )
        let coordinator = MobileShieldCoordinator(
            store: store,
            relay: PushRelayClient(
                configuration: PushRelayConfiguration(
                    endpoint: URL(string: "https://relay.test/v1/push")!,
                    enabled: true,
                    hmacSecret: "race-hmac"
                ),
                transport: NullPushTransport()
            )
        )
        let idle = MenuBarTickerSnapshot(
            walletBalance: 4,
            spendableBalance: 4,
            focusState: nil,
            focusElapsedSeconds: 0,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1,
            currentStreak: 0,
            highestStreak: 0,
            lifetimeSurplus: 0,
            isFridayRest: false,
            isCurfew: false,
            isClockTampered: false,
            localDayKey: "2026-09-13",
            weekdayCaption: "Sunday",
            dayStateCaption: "Idle"
        )
        let foodStatus = EnforcementStatus(
            mode: .hard,
            isLockedDown: false,
            activePassKind: .food,
            remainingPassSeconds: 1_800,
            activePasses: [ActivePassStatus(kind: .food, remainingSeconds: 1_800)]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        async let tick = coordinator.publish(
            ticker: idle,
            status: EnforcementStatus(),
            now: now,
            event: .focusTick
        )
        async let purchase = coordinator.publish(
            ticker: idle,
            status: foodStatus,
            now: now.addingTimeInterval(0.05),
            event: .passRedeemed(kind: .food, durationSeconds: 1_800)
        )
        _ = await (tick, purchase)
        #expect(coordinator.currentState.hasMobilePass)
        #expect(try store.load()?.hasMobilePass == true)
    }
}

private struct EmptySecrets: SecretProviding {
    func secret(service: String, account: String) -> String? {
        _ = (service, account)
        return nil
    }
}

private struct NullPushTransport: HTTPTransporting {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.test/v1/push")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }
}
