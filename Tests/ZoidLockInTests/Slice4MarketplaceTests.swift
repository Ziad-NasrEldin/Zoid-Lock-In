import AppKit
import Darwin
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer
import ZoidLockInFilterExtension
import ZoidLockInIPC

@Suite("Slice 4 marketplace and enforcer integration")
struct Slice4MarketplaceTests {
    @Test("ledger debit reduces spendable balance when purchasing a pass")
    func ledgerDebitsOnPurchase() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 6.0)
        let daemon = makeDaemon(harness, boot: "boot-debit")
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono
        )

        let purchase = try await coordinator.purchase(.food)
        #expect(purchase.cost == 2.5)
        #expect(harness.engine.walletBalance == 3.5)
        #expect(purchase.voucher?.isVerified == true)
        #expect(try await daemon.queryStatus().activePassKind == .food)
        #expect(try await daemon.queryStatus().remainingPassSeconds == 1_800)
        let spends = try harness.ledger.allTransactions().filter { $0.transactionType == .spend }
        #expect(spends.count == 1)
        #expect(spends[0].amount == -2.5)
        #expect(spends[0].referenceID == AmenityKind.food.rawValue)
    }

    @Test("curfew rejects entertainment and food but permits rest")
    func curfewRejectsEntertainmentAllowsRest() async throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try seed(harness, credits: 10.0)
        let daemon = makeDaemon(harness, boot: "boot-curfew")
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono
        )

        harness.jumpTo(year: 2026, month: 9, day: 10, hour: 22, minute: 0)
        do {
            _ = try await coordinator.purchase(.food)
            Issue.record("food must fail during curfew")
        } catch let error as ExchangeEngineError {
            #expect(error == .curfew)
            #expect(error.localizedDescription.contains("22:00"))
        }
        do {
            _ = try await coordinator.purchase(.streaming)
            Issue.record("streaming must fail during curfew")
        } catch let error as ExchangeEngineError {
            #expect(error == .curfew)
        }
        #expect(harness.engine.walletBalance == 10.0)
        #expect(try await daemon.queryStatus().isLockedDown)

        let rest = try await coordinator.purchase(.rest)
        #expect(rest.cost == 0.5)
        #expect(rest.voucher == nil)
        #expect(harness.engine.walletBalance == 9.5)
        #expect(coordinator.localRemaining(at: harness.mono.nowSeconds())[.rest] == 1_800)
        #expect(coordinator.purchaseError == nil)
        #expect(try coordinator.snapshot(status: try await daemon.queryStatus()).purchaseError == nil)
    }

    @Test("insufficient balance is rejected with a clear error")
    func insufficientBalanceRejected() async throws {
        let harness = EngineHarness(hour: 11, minute: 0)
        try seed(harness, credits: 1.0)
        let daemon = makeDaemon(harness, boot: "boot-funds")
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono
        )

        do {
            _ = try await coordinator.purchase(.food)
            Issue.record("food at 2.5 must fail with 1.0 credits")
        } catch let error as ExchangeEngineError {
            guard case .insufficientCredits(let need, let have) = error else {
                Issue.record("expected insufficientCredits, got \(error)")
                return
            }
            #expect(need == 2.5)
            #expect(have == 1.0)
            #expect(error.localizedDescription.contains("1.0"))
            #expect(error.localizedDescription.contains("2.5"))
        }
        #expect(harness.engine.walletBalance == 1.0)
        #expect(try await daemon.queryStatus().isLockedDown)
        #expect(coordinator.purchaseError?.contains("Insufficient") == true)
    }

    @Test("Friday rest mode zeros basic comforts and still issues a food voucher")
    func fridayRestZeroCostStillRedeems() async throws {
        let friday = EngineHarness(year: 2026, month: 9, day: 11, hour: 10, minute: 0)
        #expect(friday.civil.isFriday(friday.wall.now()))
        let daemon = makeDaemon(friday, boot: "boot-friday")
        let coordinator = MarketplaceCoordinator(
            engine: friday.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: friday.mono
        )

        let food = try await coordinator.purchase(.food)
        #expect(food.cost == 0)
        #expect(friday.engine.walletBalance == 0)
        #expect(food.voucher?.isVerified == true)
        #expect(try await daemon.queryStatus().activePasses.map(\.kind).contains(.food))

        try await coordinator.purchase(.phone)
        #expect(friday.engine.walletBalance == 0)
        #expect(try await daemon.queryStatus().activePasses.map(\.kind).contains(.phone))

        do {
            _ = try await coordinator.purchase(.outing)
            Issue.record("outing still costs 5.0 on Friday")
        } catch let error as ExchangeEngineError {
            guard case .insufficientCredits(let need, let have) = error else {
                Issue.record("expected insufficient credits, got \(error)")
                return
            }
            #expect(need == 5.0)
            #expect(have == 0)
        }
    }

    @Test("food and phone passes run concurrently and expire independently")
    func concurrentPassesExpireIndependently() async throws {
        let clock = ManualMonotonicClock(startingAt: 0)
        let hub = FilterPolicyHub()
        let runtime = Slice4ProcessRuntime(
            processes: [RunningProcess(pid: 202, name: "Steam")]
        )
        let daemon = EnforcementDaemon(
            processSentinel: ProcessSentinel(runtime: runtime, scanInterval: 1.5),
            clock: clock,
            wallClock: SliceTestCivil.daytimeWall,
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-concurrent",
            civilClock: SliceTestCivil.civil
        )

        daemon.commitKindScopedPass(kind: .food, durationSeconds: 1_800)
        daemon.commitKindScopedPass(kind: .phone, durationSeconds: 3_600)

        let engine = ContentFilterEngine(statusReader: hub)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "web.whatsapp.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        #expect(daemon.processSentinel.scanAndTerminate().map(\.pid).contains(202))

        let status = try await daemon.queryStatus()
        #expect(Set(status.activePasses.map(\.kind)) == [.food, .phone])
        #expect(status.activePasses.first { $0.kind == .food }?.remainingSeconds == 1_800)
        #expect(status.activePasses.first { $0.kind == .phone }?.remainingSeconds == 3_600)

        clock.advance(by: 1_800)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())

        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "web.whatsapp.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        let afterFood = try await daemon.queryStatus()
        #expect(afterFood.activePassKind == .phone)
        #expect(Set(afterFood.activePasses.map(\.kind)) == [.phone])
        #expect(afterFood.remainingPassSeconds == 1_800)

        clock.advance(by: 1_800)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(engine.verdict(hostname: "web.whatsapp.com", port: 443, transport: .tcp) == .drop)
        #expect(try await daemon.queryStatus().isLockedDown)
    }

    @Test("streaming remains allowed after food expires; gaming kills resume at minute 30")
    func categoricalExpiryRelocksOnlyTheExpiredKind() async throws {
        let clock = ManualMonotonicClock(startingAt: 10)
        let hub = FilterPolicyHub()
        let runtime = Slice4ProcessRuntime(
            processes: [
                RunningProcess(pid: 202, name: "Steam"),
                RunningProcess(pid: 303, name: "Discord"),
            ]
        )
        let daemon = EnforcementDaemon(
            processSentinel: ProcessSentinel(runtime: runtime, scanInterval: 1.5),
            clock: clock,
            wallClock: SliceTestCivil.daytimeWall,
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-expiry",
            civilClock: SliceTestCivil.civil
        )
        daemon.commitKindScopedPass(kind: .food, durationSeconds: 1_800)
        daemon.commitKindScopedPass(kind: .streaming, durationSeconds: 3_600)
        daemon.commitKindScopedPass(kind: .gaming, durationSeconds: 1_800)

        let engine = ContentFilterEngine(statusReader: hub)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .allow)
        #expect(daemon.processSentinel.scanAndTerminate().isEmpty)

        clock.advance(by: 1_800)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())

        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .allow)
        let killed = daemon.processSentinel.scanAndTerminate()
        #expect(Set(killed.map(\.pid)) == Set([202, 303]))
        #expect(try await daemon.queryStatus().activePassKind == .streaming)
    }

    @Test("XPC voucher redemption verifies HMAC and rejects tamper and replay")
    func xpcVoucherVerification() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 10.0)
        let daemon = makeDaemon(harness, boot: "boot-voucher")
        let issuer = AmenityVoucherIssuer()
        let purchase = try harness.engine.purchaseAmenity(.food, issuer: issuer)
        let voucher = try #require(purchase.voucher)
        #expect(voucher.isVerified)
        #expect(!AmenityPassVoucher().isVerified)

        let exporter = EnforcementXPCExporter(service: daemon)
        let data = try JSONEncoder().encode(voucher)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.redeemAmenityVoucher(data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        #expect(try await daemon.queryStatus().activePassKind == .food)

        do {
            try await daemon.redeemAmenityVoucher(voucher)
            Issue.record("replayed nonce must be rejected")
        } catch let error as EnforcementControlError {
            #expect(error == .replayNonceRejected)
        }

        var tampered = voucher
        if tampered.payload.isEmpty == false {
            tampered.payload[0] ^= 0x5A
        }
        do {
            try await daemon.redeemAmenityVoucher(tampered)
            Issue.record("tampered voucher must fail")
        } catch let error as EnforcementControlError {
            guard case .invalidAmenityVoucher = error else {
                Issue.record("expected invalidAmenityVoucher, got \(error)")
                return
            }
        }

        await #expect(throws: EnforcementControlError.amenityPassRequiresVoucher) {
            try await daemon.openPass(kind: .streaming, durationSeconds: 3_600, nonce: "no-voucher")
        }
    }

    @Test("marketplace coordinator XPC flow purchases food then phone together")
    func coordinatorPurchasesConcurrentPasses() async throws {
        let harness = EngineHarness(hour: 10, minute: 0)
        try seed(harness, credits: 10.0)
        let daemon = makeDaemon(harness, boot: "boot-market")
        let coordinator = MarketplaceCoordinator(
            engine: harness.engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: daemon,
            clock: harness.mono
        )

        try await coordinator.purchase(.food)
        try await coordinator.purchase(.phone)
        #expect(harness.engine.walletBalance == 6.0)

        let status = try await daemon.queryStatus()
        #expect(Set(status.activePasses.map(\.kind)) == [.food, .phone])
        let snapshot = try coordinator.snapshot(status: status)
        #expect(snapshot.spendableBalance == 6.0)
        #expect(snapshot.items.first { $0.kind == .food }?.isActive == true)
        #expect(snapshot.items.first { $0.kind == .phone }?.isActive == true)
        #expect(snapshot.items.first { $0.kind == .food }?.remainingSeconds == 1_800)
        #expect(snapshot.items.first { $0.kind == .phone }?.remainingSeconds == 3_600)
    }

    @MainActor
    @Test("renders a high-resolution SUMI-E marketplace proof PNG")
    func marketplaceProofPNG() throws {
        let url = MarketplaceProofRenderer.defaultProofURL
        try MarketplaceProofRenderer.renderPNG(snapshot: .proof, to: url, scale: 3)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        #expect(data.count > 12_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 440)
        #expect((image?.size.height ?? 0) >= 660)

        #expect(MarketplaceSnapshot.proof.isCurfew == false)
        #expect(MarketplaceSnapshot.proof.activeItems.count == 2)
        #expect(MarketplaceSnapshot.proof.items.count == AmenityKind.allCases.count)
        #expect(MarketplaceSnapshot.proof.curfewCaption.contains("22:00"))
        #expect(MarketplaceSnapshot.proof.formattedVault.contains("42.5"))
    }

    @Test("curfew snapshot surfaces the warning and locks entertainment buy labels")
    func curfewSnapshotWarning() throws {
        let curfewTicker = MenuBarTickerSnapshot(
            walletBalance: 6.5,
            spendableBalance: 6.5,
            focusState: nil,
            focusElapsedSeconds: 0,
            focusRemainingToNextMintSeconds: 0,
            focusCreditsEarned: 0,
            multiplierApplied: 1.0,
            currentStreak: 7,
            highestStreak: 12,
            lifetimeSurplus: 42.5,
            isFridayRest: false,
            isCurfew: true,
            isClockTampered: false,
            localDayKey: "2026-09-12",
            weekdayCaption: "Saturday",
            dayStateCaption: "Curfew"
        )
        let snapshot = MarketplaceSnapshot.assemble(ticker: curfewTicker)
        #expect(snapshot.isCurfew)
        #expect(snapshot.curfewCaption.contains("CURFEW ACTIVE"))
        #expect(snapshot.items.first { $0.kind == .food }?.isBlockedByCurfew == true)
        #expect(snapshot.items.first { $0.kind == .rest }?.isBlockedByCurfew == false)
        #expect(snapshot.items.first { $0.kind == .bed }?.isBlockedByCurfew == false)
    }

    @Test("legacy filter snapshots without activePasses still decode")
    func legacySnapshotDecode() throws {
        let legacy = """
        {"activePassKind":"food","isLockedDown":false,"isPassActive":true,"policy":{"blacklistedSuffixes":["youtube.com"],"inspectedPorts":[80,443,8080,1080],"mode":"hard","processScanIntervalSeconds":1.5,"processTargetNames":["Steam"],"whitelistedSuffixes":[]},"remainingPassSeconds":1800}
        """
        let snapshot = try JSONDecoder().decode(
            FilterEnforcementSnapshot.self,
            from: Data(legacy.utf8)
        )
        #expect(snapshot.activePassKind == .food)
        #expect(snapshot.resolvedPassKinds == [.food])
        #expect(snapshot.activePasses.first?.remainingSeconds == 1_800)
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

private final class Slice4ProcessRuntime: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private var processGroups: [Int32: Int32]
    private(set) var sentSignals: [Int32: [Int32]] = [:]
    private(set) var sentGroupSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess], processGroups: [Int32: Int32] = [:]) {
        self.processes = processes
        self.processGroups = processGroups
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
        lock.lock()
        defer { lock.unlock() }
        return processGroups[pid] ?? pid
    }

    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentGroupSignals[pgid, default: []].append(signal)
        return true
    }
}
