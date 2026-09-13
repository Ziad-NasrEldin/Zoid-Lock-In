import Darwin
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer
import ZoidLockInFilterExtension

@Suite("Slice 4 adversarial hardening")
struct Slice4AdversarialHardeningTests {
    @Test("redeemed nonce and transactionID survive a simulated helper restart")
    func durableReplayRejectedAcrossDaemonRestart() async throws {
        let directory = FileEmergencyIncidentStore.makeIsolatedDirectory()
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 6.0)
        let issuer = AmenityVoucherIssuer()
        let purchase = try harness.engine.purchaseAmenity(.food, issuer: issuer)
        let voucher = try #require(purchase.voucher)

        let first = makeJournalDaemon(
            harness: harness,
            directory: directory,
            boot: "boot-replay",
            clockStart: 100
        )
        try await first.redeemAmenityVoucher(voucher)
        #expect(try await first.queryStatus().activePassKind == .food)
        #expect(try await first.queryStatus().remainingPassSeconds == 1_800)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(FileRedemptionJournal.defaultFileName).path
        )
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o777 == 0o600)

        harness.mono.advance(by: 120)
        let restarted = makeJournalDaemon(
            harness: harness,
            directory: directory,
            boot: "boot-replay",
            clockStart: harness.mono.nowSeconds()
        )
        let restored = try await restarted.queryStatus()
        #expect(restored.activePassKind == .food)
        #expect(restored.remainingPassSeconds == 1_680)

        do {
            try await restarted.redeemAmenityVoucher(voucher)
            Issue.record("same voucher must not grant a second pass after restart")
        } catch let error as EnforcementControlError {
            #expect(error == .replayNonceRejected)
        }

        let replayedTransaction = issuer.issue(
            kind: .food,
            durationSeconds: 1_800,
            nonce: UUID().uuidString,
            transactionID: purchase.transaction.id,
            issuedAt: harness.wall.now()
        )
        do {
            try await restarted.redeemAmenityVoucher(replayedTransaction)
            Issue.record("same transactionID must not grant a second pass")
        } catch let error as EnforcementControlError {
            #expect(error == .replayNonceRejected)
        }

        let rebooted = makeJournalDaemon(
            harness: harness,
            directory: directory,
            boot: "boot-next",
            clockStart: harness.mono.nowSeconds()
        )
        #expect(try await rebooted.queryStatus().isLockedDown)
        do {
            try await rebooted.redeemAmenityVoucher(voucher)
            Issue.record("reboot must still reject the redeemed ticket")
        } catch let error as EnforcementControlError {
            #expect(error == .replayNonceRejected)
        }
    }

    @Test("vouchers expire 300s after issue if they are not redeemed")
    func voucherTTLExpirationRejected() throws {
        let issuer = AmenityVoucherIssuer()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let voucher = issuer.issue(
            kind: .streaming,
            durationSeconds: 3_600,
            nonce: UUID().uuidString,
            transactionID: UUID(),
            issuedAt: issuedAt
        )
        let verifier = AmenityVoucherVerifier()
        #expect(throws: AmenityVoucherError.expired) {
            try verifier.verify(
                voucher,
                now: issuedAt.addingTimeInterval(AmenityVoucherPolicy.timeToLiveSeconds + 1)
            )
        }
        let claims = try verifier.verify(voucher, now: issuedAt.addingTimeInterval(5))
        #expect(claims.issuedAt == issuedAt)
        #expect(claims.kind == .streaming)
    }

    @Test("daemon reject of an expired voucher does not install a pass")
    func daemonRejectsExpiredVoucher() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        let issuer = AmenityVoucherIssuer()
        let voucher = issuer.issue(
            kind: .food,
            durationSeconds: 1_800,
            nonce: UUID().uuidString,
            transactionID: UUID(),
            issuedAt: harness.wall.now().addingTimeInterval(-301)
        )
        let daemon = makeDaemon(harness, boot: "boot-ttl")
        do {
            try await daemon.redeemAmenityVoucher(voucher)
            Issue.record("expired voucher must not redeem")
        } catch let error as EnforcementControlError {
            guard case .invalidAmenityVoucher(let reason) = error else {
                Issue.record("expected invalidAmenityVoucher, got \(error)")
                return
            }
            #expect(reason.localizedCaseInsensitiveContains("ttl") || reason.localizedCaseInsensitiveContains("expired"))
        }
        #expect(try await daemon.queryStatus().isLockedDown)
    }

    @Test("XPC redeem failure appends REFUND_AMENITY and restores the balance")
    func compensatingRefundOnXPCFailure() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 6.0)
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: FailingRedeemer(),
            clock: harness.mono
        )

        do {
            _ = try await coordinator.purchase(.food)
            Issue.record("XPC failure must surface to the buyer")
        } catch let error as EnforcementControlError {
            guard case .invalidAmenityVoucher = error else {
                Issue.record("expected invalidAmenityVoucher, got \(error)")
                return
            }
        }

        #expect(harness.engine.walletBalance == 6.0)
        let transactions = try harness.ledger.allTransactions()
        let spends = transactions.filter { $0.transactionType == .spend }
        let refunds = transactions.filter { $0.transactionType == .refund }
        #expect(spends.count == 1)
        #expect(refunds.count == 1)
        #expect(refunds[0].amount == 2.5)
        #expect(refunds[0].transactionType.rawValue == "refund_amenity")
        #expect(refunds[0].description.contains("REFUND_AMENITY"))
        #expect(refunds[0].referenceID == spends[0].id.uuidString)
        #expect(try coordinator.snapshot().purchaseError != nil)
    }

    @Test("in-flight purchase guard rejects a second debit")
    func purchaseInFlightGuard() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 10.0)
        let gate = GateRedeemer()
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: gate,
            clock: harness.mono
        )

        let first = Task {
            try await coordinator.purchase(.food)
        }

        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.purchaseInFlight)
        #expect(gate.isWaiting)

        do {
            _ = try await coordinator.purchase(.gaming)
            Issue.record("second click must not debit")
        } catch let error as MarketplaceCoordinatorError {
            #expect(error == .purchaseInFlight)
        }

        gate.fail(EnforcementControlError.invalidAmenityVoucher("xpc down"))
        do {
            _ = try await first.value
            Issue.record("first purchase should fail after the mocked XPC error")
        } catch let error as EnforcementControlError {
            guard case .invalidAmenityVoucher = error else {
                Issue.record("expected invalidAmenityVoucher, got \(error)")
                return
            }
        }

        #expect(!coordinator.purchaseInFlight)
        #expect(harness.engine.walletBalance == 10.0)
        let spends = try harness.ledger.allTransactions().filter { $0.transactionType == .spend }
        #expect(spends.count == 1)
        let refunds = try harness.ledger.allTransactions().filter { $0.transactionType == .refund }
        #expect(refunds.count == 1)
    }

    @Test("21:55 food purchase clips daemon duration to 300 seconds")
    func curfewDurationClipping() async throws {
        let harness = EngineHarness(hour: 21, minute: 55)
        try seed(harness, credits: 6.0)
        #expect(harness.civil.secondsUntilCurfew(harness.wall.now()) == 300)
        let daemon = makeDaemon(harness, boot: "boot-clip")
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono
        )

        let purchase = try await coordinator.purchase(.food)
        #expect(purchase.cost == 2.5)
        let status = try await daemon.queryStatus()
        #expect(status.activePassKind == .food)
        #expect(status.remainingPassSeconds == 300)
        #expect(harness.engine.walletBalance == 3.5)
    }

    @Test("daemon rejects curfew-sensitive redeem after 22:00 and revokes live entertainment")
    func curfewRejectAndWatchdogRevoke() async throws {
        let harness = EngineHarness(hour: 21, minute: 58)
        try seed(harness, credits: 6.0)
        let issuer = AmenityVoucherIssuer()
        let purchase = try harness.engine.purchaseAmenity(.food, issuer: issuer)
        let voucher = try #require(purchase.voucher)

        let daemon = makeDaemon(harness, boot: "boot-curfew-redeem")
        harness.jumpTo(year: 2026, month: 9, day: 10, hour: 22, minute: 0)
        do {
            try await daemon.redeemAmenityVoucher(voucher)
            Issue.record("redeem during curfew must fail closed")
        } catch let error as EnforcementControlError {
            #expect(error == .curfewActive)
        }
        #expect(try await daemon.queryStatus().isLockedDown)

        let live = EngineHarness(hour: 21, minute: 50)
        let liveDaemon = makeDaemon(live, boot: "boot-curfew-watchdog")
        liveDaemon.commitKindScopedPass(kind: .food, durationSeconds: 1_800)
        liveDaemon.commitKindScopedPass(kind: .streaming, durationSeconds: 3_600)
        #expect(try await liveDaemon.queryStatus().activePasses.count == 2)

        live.jumpTo(year: 2026, month: 9, day: 10, hour: 22, minute: 0)
        liveDaemon.evaluateWatchdogs(at: live.mono.nowSeconds())
        #expect(try await liveDaemon.queryStatus().isLockedDown)
        #expect(try await liveDaemon.queryStatus().activePasses.isEmpty)
    }

    @Test("streaming CDNs drop without a pass and unblock with a streaming pass")
    func streamingCDNDomainBlockingAndUnblocking() async throws {
        let locked = ContentFilterEngine()
        for host in [
            "googlevideo.com",
            "r5---sn-abc.googlevideo.com",
            "ytimg.com",
            "yt3.ggpht.com",
            "nflxvideo.net",
            "nflxext.com",
            "nflximg.net",
            "ttvnw.net",
            "jtvnw.net",
            "cdninstagram.com",
            "fbcdn.net",
            "redditstatic.com",
            "redditmedia.com",
        ] {
            #expect(
                locked.verdict(hostname: host, port: 443, transport: .tcp) == .drop,
                "Expected drop for \(host)"
            )
        }

        let hub = FilterPolicyHub()
        let daemon = EnforcementDaemon(
            wallClock: SliceTestCivil.daytimeWall,
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-cdn",
            civilClock: SliceTestCivil.civil
        )
        daemon.commitKindScopedPass(kind: .streaming, durationSeconds: 3_600)
        let engine = ContentFilterEngine(statusReader: hub)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "googlevideo.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "ytimg.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "nflxvideo.net", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "ttvnw.net", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "cdninstagram.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "redditstatic.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
    }

    @Test("process sentinel matches and terminates steamapps/common game paths")
    func gamePathMatchingAndTerminate() {
        let matcher = ProcessTargetMatcher()
        #expect(
            matcher.matches(
                processName: "Game",
                executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/SomeTitle/Game"
            )
        )
        #expect(matcher.matches(processName: "dota2"))
        #expect(matcher.matches(processName: "cs2"))
        #expect(matcher.matches(processName: "hl2_osx"))
        #expect(matcher.matches(processName: "World of Warcraft"))

        let runtime = HardeningProcessRuntime(
            processes: [
                RunningProcess(
                    pid: 404,
                    name: "Game",
                    executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/SomeTitle/Game"
                ),
                RunningProcess(
                    pid: 405,
                    name: "dota2",
                    executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/dota 2 beta/dota2"
                ),
                RunningProcess(pid: 406, name: "Safari"),
            ]
        )
        let sentinel = ProcessSentinel(runtime: runtime, scanInterval: 1.5)
        let killed = sentinel.scanAndTerminate()
        #expect(Set(killed.map(\.pid)) == Set([404, 405]))
        #expect(runtime.sentSignals[404] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentSignals[405] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentSignals[406] == nil)
    }

    @Test("pass clock is CLOCK_MONOTONIC so sleep continues to consume the pass")
    func monotonicClockAlignment() {
        let continuous = MachContinuousTimeClock().nowSeconds()
        let monotonic = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #expect(abs(continuous - monotonic) < 0.05)
        #expect(FileRedemptionJournal.defaultFileName == "redemption_journal.json")
        #expect(FileEmergencyIncidentStore.defaultDirectoryPath == "/var/db/zoidlockin")
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

private func makeDaemon(_ harness: EngineHarness, boot: String) -> EnforcementDaemon {
    EnforcementDaemon(
        clock: harness.mono,
        wallClock: harness.wall,
        incidentStore: InMemoryEmergencyIncidentStore(),
        bootSessionUUID: boot,
        voucherVerifier: AmenityVoucherVerifier(),
        civilClock: harness.civil
    )
}

private func makeJournalDaemon(
    harness: EngineHarness,
    directory: URL,
    boot: String,
    clockStart: TimeInterval
) -> EnforcementDaemon {
    harness.mono.set(clockStart)
    return EnforcementDaemon(
        clock: harness.mono,
        wallClock: harness.wall,
        incidentStore: InMemoryEmergencyIncidentStore(),
        bootSessionUUID: boot,
        storageDirectory: directory,
        voucherVerifier: AmenityVoucherVerifier(),
        redemptionJournal: FileRedemptionJournal(directory: directory),
        civilClock: harness.civil
    )
}

private struct FailingRedeemer: AmenityPassRedeeming {
    func redeemAmenityVoucher(_ voucher: AmenityPassVoucher) async throws {
        _ = voucher
        throw EnforcementControlError.invalidAmenityVoucher("xpc down")
    }
}

private final class GateRedeemer: AmenityPassRedeeming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func redeemAmenityVoucher(_ voucher: AmenityPassVoucher) async throws {
        _ = voucher
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        continuation?.resume(throwing: error)
        continuation = nil
        lock.unlock()
    }
}

private final class HardeningProcessRuntime: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private(set) var sentSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess]) {
        self.processes = processes
    }

    func listRunningProcesses() -> [RunningProcess] {
        lock.lock()
        defer { lock.unlock() }
        return processes
    }

    func terminate(pid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentSignals[pid, default: []].append(signal)
        if signal == SIGKILL {
            processes.removeAll { $0.pid == pid }
        }
        return true
    }

    func processGroupID(for pid: Int32) -> Int32? {
        pid
    }

    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        _ = (pgid, signal)
        return true
    }
}
