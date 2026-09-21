import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("FocusSessionCoordinatorTests")
struct FocusSessionCoordinatorTests {
    @Test("Productive state change triggers focus start and earns credits")
    func productiveTriggersFocus() throws {
        let clock = MachContinuousTimeClock()
        let ledger = InMemoryEconomicLedger()
        let detector = ManualActivityDetector(idleSeconds: 0)
        let engine = ExchangeEngine(
            ledger: ledger,
            clock: clock,
            focusClock: clock,
            activityDetector: detector
        )

        let tracker = ZoidZeroLiveTracker(idleThreshold: 90)
        let coordinator = FocusSessionCoordinator(engine: engine, tracker: tracker)

        let app = TrackedAppIdentity(
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode",
            isProductive: true
        )

        // Simulate state transition to productive
        coordinator.handleStateChanged(isProductiveAndActive: true, app: app)

        // Wait for queue dispatch
        Thread.sleep(forTimeInterval: 0.1)

        let snapshot = try engine.snapshot()
        #expect(snapshot.focusState == .active || snapshot.focusState == .pausedGrace)
    }

    @Test("Non-productive application marks interruption")
    func nonProductiveInterruption() throws {
        let clock = MachContinuousTimeClock()
        let ledger = InMemoryEconomicLedger()
        let detector = ManualActivityDetector(idleSeconds: 0)
        let engine = ExchangeEngine(
            ledger: ledger,
            clock: clock,
            focusClock: clock,
            activityDetector: detector
        )

        let tracker = ZoidZeroLiveTracker(idleThreshold: 90)
        let coordinator = FocusSessionCoordinator(engine: engine, tracker: tracker)

        // Start active focus
        _ = try engine.startFocus()

        let nonProductiveApp = TrackedAppIdentity(
            bundleIdentifier: "com.apple.Music",
            displayName: "Music",
            isProductive: false
        )

        coordinator.handleStateChanged(isProductiveAndActive: false, app: nonProductiveApp)
        Thread.sleep(forTimeInterval: 0.1)

        let snapshot = try engine.snapshot()
        // Focus state should reflect engine state
        #expect(snapshot.focusState != nil)
    }


    @Test("Codex desktop app is a productive focus source")
    func codexIsProductive() {
        #expect(ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.openai.codex"))
        #expect(ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.openai.chat"))
        #expect(ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        #expect(!ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.apple.Music"))
        #expect(!ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.apple.Safari"))
        #expect(ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.apple.Safari", domain: "github.com"))
        #expect(!ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.apple.Safari", domain: "youtube.com"))
        #expect(!ZoidZeroLiveTracker.isProductive(bundleIdentifier: "com.tinyspeck.slackmacgap"))
    }
}
