import AppKit
import SwiftUI
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInIPC

@main
enum ZoidLockInAppEntry {
    static func main() {
        if CommandLine.arguments.contains("--render-menubar-proof") {
            renderMenuBarProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-marketplace-proof") {
            renderMarketplaceProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-mobile-shield-proof") {
            renderMobileShieldProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-offline-meeting-proof") {
            renderOfflineMeetingProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-gemini-audit-proof") {
            renderGeminiAuditProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-micro-habits-proof") {
            renderMicroHabitsProofAndExit()
            return
        }
        if CommandLine.arguments.contains("--render-desktop-dashboard-proof")
            || CommandLine.arguments.contains("--render-calibration-mode-proof") {
            renderDesktopDashboardProofAndExit()
            return
        }
        ZoidLockInMenuBarApp.main()
    }

    @MainActor
    private static func renderMenuBarProofAndExit() {
        do {
            try MenuBarTickerProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(MenuBarTickerProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Menu bar proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderMarketplaceProofAndExit() {
        do {
            try MarketplaceProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(MarketplaceProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Marketplace proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderMobileShieldProofAndExit() {
        do {
            try MobileShieldProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(MobileShieldProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Mobile shield proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderOfflineMeetingProofAndExit() {
        do {
            try OfflineMeetingProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(OfflineMeetingProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Offline meeting proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderGeminiAuditProofAndExit() {
        do {
            try GeminiAuditProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(GeminiAuditProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Gemini audit proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderMicroHabitsProofAndExit() {
        do {
            try MicroHabitsProofRenderer.renderPNG()
            FileHandle.standardError.write(
                Data("Wrote \(MicroHabitsProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Micro-habits proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderDesktopDashboardProofAndExit() {
        do {
            try DesktopDashboardProofRenderer.renderProofSet()
            FileHandle.standardError.write(
                Data("Wrote \(DesktopDashboardProofRenderer.defaultProofURL.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("Desktop dashboard proof render failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

final class ZoidAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ZoidLockInMenuBarApp: App {
    @NSApplicationDelegateAdaptor(ZoidAppDelegate.self) private var appDelegate
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        Window("Zoid Lock In — Command Dashboard", id: "command-dashboard") {
            CommandDashboardContainer(session: session)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarCompanionRoot(session: session)
        } label: {
            MenuBarTickerLabel(snapshot: session.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarCompanionRoot: View {
    @ObservedObject var session: MenuBarSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarExtraView(
            ticker: session.snapshot,
            snapshot: session.marketplace,
            onPurchase: session.purchase,
            onToggleFocus: session.toggleFocus,
            meeting: session.meeting,
            habits: session.habits,
            onPunchToggle: session.punchToggle,
            onSubmitMeeting: session.submitMeeting,
            onAbandonMeeting: session.abandonMeeting,
            onImportArtifact: session.importArtifact,
            onRetryAudit: session.retryMeetingAudit,
            onAppeal: session.appealMeeting,
            onCompleteHabit: session.completeHabit,
            onCreateHabit: session.createHabit,
            onOpenDashboard: {
                openWindow(id: "command-dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}

private struct CommandDashboardContainer: View {
    @ObservedObject var session: MenuBarSession

    var body: some View {
        CommandDashboardView(
            snapshot: session.dashboard,
            onUnlock: { password, totp in
                Task { await session.unlockSettings(password: password, totp: totp) }
            },
            onLock: {
                session.lockSettings()
            },
            onEnroll: { password, confirm, secret, totp in
                Task {
                    await session.enrollSettings(
                        password: password,
                        confirmation: confirm,
                        secret: secret,
                        totp: totp
                    )
                }
            },
            onTriggerEmergencyValve: {
                Task {
                    await session.triggerEmergencyValve()
                }
            },
            onUpdateAmenityPrice: { kind, cost in
                session.updateAmenityPrice(kind: kind, cost: cost)
            },
            onAddBlocklistRule: { domain in
                session.addBlocklistRule(domain: domain)
            },
            onRemoveBlocklistRule: { domain in
                session.removeBlocklistRule(domain: domain)
            },
            onUpdateAlertRecipient: { email in
                session.updateAlertRecipient(email: email)
            },
            onCreateHabit: { title, reward, freq in
                session.createHabit(title, reward: reward, frequency: freq)
            }
        )
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class MenuBarSession: ObservableObject {
    @Published var snapshot: MenuBarTickerSnapshot
    @Published var marketplace: MarketplaceSnapshot
    @Published var meeting: OfflineMeetingSnapshot
    @Published var habits: MicroHabitsSnapshot
    @Published var dashboard: CommandDashboardSnapshot

    private let coordinator: EconomyTickCoordinator
    private let marketplaceCoordinator: MarketplaceCoordinator
    private let shield: MobileShieldCoordinator
    private let meetings: OfflineSessionCoordinator
    private let auditor: OfflineMeetingAuditCoordinator
    private let purge: MeetingArtifactPurgeScheduler
    private let habitCoordinator: MicroHabitCoordinator
    private let habitGovernance: GovernanceLockCoordinator
    private let calibration: CalibrationCoordinator
    private let gatekeeper: SecurityGatekeeper
    private let ledger: SQLiteEconomicLedger
    private let incidentCache: CachedEmergencyIncidentStore
    private let client: XPCEnforcementClient
    private let economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    private var purchaseInFlight = false
    private var lastPublishedMode: EnforcementMode?
    private var lastFocusState: FocusSessionState?
    private var lastActivePassCount: Int = -1
    private var lastShieldPublishTime: Date = .distantPast
    private var lastLedgerReloadTime: Date = .distantPast
    private var lastPurgeTime: Date = .distantPast
    private var lastKnownBalance: Double = -1
    private var cachedVault: LifetimeVaultRecord = .empty
    private var cachedReconciliations: [DailyReconciliationRecord] = []
    private var cachedTransactions: [WalletTransaction] = []

    init() {
        let ledger = (try? SQLiteEconomicLedger.default()) ?? (try? SQLiteEconomicLedger())
        let resolved = ledger ?? (try! SQLiteEconomicLedger())
        let cache = CachedEmergencyIncidentStore()
        let timeTravel = TimeTravelGuard()
        let fallbackDirectory = resolved.fileURL?.deletingLastPathComponent()
            ?? EncryptedStateStore.defaultApplicationSupportDirectory()
        let gatekeeper = SecurityGatekeeper(
            keychain: FileSecureDataStore.shared,
            mail: AlertMailService(
                configuration: AlertMailConfiguration(recipient: SecurityGatekeeper.defaultRecipient)
            )
        )
        let habitGovernance = GovernanceLockCoordinator(
            store: resolved,
            clock: MachContinuousTimeClock(),
            wallClock: SystemWallClock(),
            timeTravel: timeTravel,
            keyProvider: KeychainGovernanceKeyProvider(),
            replicaSealStore: FileGovernanceSealStore(fallbackDirectory: fallbackDirectory),
            gatekeeper: gatekeeper
        )
        let pinnedTimeZone = habitGovernance.pinnedTimeZone
        let engine = ExchangeEngine(
            ledger: resolved,
            incidentStore: cache,
            clock: MachContinuousTimeClock(),
            focusClock: MachUptimeClock(),
            timeTravel: timeTravel,
            timeZone: pinnedTimeZone,
            habitWindow: resolved
        )
        let coordinator = EconomyTickCoordinator(engine: engine, incidentCache: cache)
        let client = XPCEnforcementClient()
        client.resume()
        client.startHeartbeatLoop()
        let calibration = CalibrationCoordinator(
            store: resolved,
            clock: MachContinuousTimeClock(),
            wallClock: SystemWallClock(),
            timeTravel: timeTravel,
            timeZone: pinnedTimeZone,
            keyProvider: KeychainCalibrationKeyProvider(),
            replicaSealStore: FileCalibrationSealStore(fallbackDirectory: fallbackDirectory)
        )
        habitGovernance.onBlocklistChanged = { rules in
            let snapshot = EnforcementPolicySnapshot(
                EnforcementPolicy(domainRules: rules, mode: calibration.enforcementMode())
            )
            Task {
                try? await client.applyPolicy(snapshot)
            }
        }
        let shieldStore = EncryptedStateStore(
            fallbackDirectory: EncryptedStateStore.defaultApplicationSupportDirectory(),
            keyProvider: KeychainMobileShieldKeyProvider(),
            highWater: KeychainSequenceHighWater()
        )
        let shield = MobileShieldCoordinator(
            store: shieldStore,
            relay: PushRelayClient(
                configuration: PushRelayConfiguration.resolve()
            )
        )
        let marketplaceCoordinator = MarketplaceCoordinator(
            engine: engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: client,
            shield: shield
        )
        let artifactStore = MeetingArtifactStore.default()
        let meetings = OfflineSessionCoordinator(
            store: resolved,
            artifacts: artifactStore,
            clock: MachContinuousTimeClock(),
            uptimeClock: MachUptimeClock(),
            wallClock: SystemWallClock(),
            timeTravel: timeTravel
        )
        meetings.bindFocusEngine(engine)
        let habitCoordinator = MicroHabitCoordinator(
            store: resolved,
            engine: engine,
            governance: habitGovernance,
            timeZone: pinnedTimeZone
        )
        habitGovernance.publishLiveSettings()
        if let existing = try? resolved.allHabits(), existing.isEmpty {
            let now = Date()
            for starter in MicroHabit.defaultCatalog(now: now) {
                try? resolved.upsertHabit(starter)
            }
        }
        let auditor = OfflineMeetingAuditCoordinator(
            store: resolved,
            artifacts: artifactStore,
            engine: engine,
            client: GeminiAuditClient(),
            session: meetings
        )
        let purge = MeetingArtifactPurgeScheduler(
            store: resolved,
            artifacts: artifactStore
        )
        _ = try? purge.purgeExpired()

        self.coordinator = coordinator
        self.marketplaceCoordinator = marketplaceCoordinator
        self.shield = shield
        self.meetings = meetings
        self.auditor = auditor
        self.purge = purge
        self.habitCoordinator = habitCoordinator
        self.habitGovernance = habitGovernance
        self.calibration = calibration
        self.gatekeeper = gatekeeper
        self.ledger = resolved
        self.incidentCache = cache
        self.client = client
        let initial = (try? engine.snapshot()) ?? .proof
        self.snapshot = initial
        self.marketplace = MarketplaceSnapshot.assemble(ticker: initial)
        self.meeting = meetings.snapshot()
        let initialHabits = habitCoordinator.snapshot(ticker: initial)
        self.habits = initialHabits
        let initialVault = (try? resolved.loadVault()) ?? .empty
        let initialReconciliations = (try? resolved.allReconciliations()) ?? []
        let initialTransactions = (try? resolved.allTransactions()) ?? []
        self.cachedVault = initialVault
        self.cachedReconciliations = initialReconciliations
        self.cachedTransactions = initialTransactions
        self.lastKnownBalance = initial.spendableBalance
        self.lastFocusState = initial.focusState
        self.lastActivePassCount = 0

        self.dashboard = CommandDashboardSnapshot.assemble(
            ticker: initial,
            calibration: calibration.snapshot(),
            vault: initialVault,
            reconciliations: initialReconciliations,
            transactions: initialTransactions,
            security: gatekeeper.snapshot(),
            governance: habitGovernance.snapshot(),
            amenityPrices: (try? habitGovernance.amenityPriceOverrides()) ?? [:],
            blocklistRules: (try? habitGovernance.blocklistRules()) ?? [],
            habits: initialHabits.habits
        )
        lastPublishedMode = nil
        Task {
            do {
                let mode = calibration.enforcementMode()
                try await client.applyPolicy(
                    EnforcementPolicySnapshot(
                        EnforcementPolicy(mode: mode)
                    )
                )
                await MainActor.run { [weak self] in
                    self?.lastPublishedMode = mode
                }
            } catch {
                _ = error
            }
        }

        let coalescer = TickCoalescer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self, coordinator, client, marketplaceCoordinator, shield, meetings, purge, habitCoordinator, calibration, habitGovernance, ledger = resolved, cache, gatekeeper] in
            guard let self, coalescer.begin() else { return }
            Task {
                defer { coalescer.end() }
                let next = await coordinator.reconcileIncidentsAndTick(
                    fetchIncidents: { try await client.queryUnleviedEmergencyIncidents() },
                    markLevied: { try await client.markEmergencyIncidentLevied(uuid: $0) }
                )
                let status = try? await client.queryStatus()
                let now = Date()

                let activePassesCount = status?.activePasses.count ?? 0
                let shouldPublishShield = next.focusState != self.lastFocusState
                    || activePassesCount != self.lastActivePassCount
                    || now.timeIntervalSince(self.lastShieldPublishTime) >= 60

                let shieldStatus: MobileShieldStatus
                if shouldPublishShield {
                    let publication = await shield.publish(
                        ticker: next,
                        status: status,
                        now: now,
                        event: .focusTick
                    )
                    self.lastFocusState = next.focusState
                    self.lastActivePassCount = activePassesCount
                    self.lastShieldPublishTime = now
                    shieldStatus = publication.status
                } else {
                    shieldStatus = shield.currentStatus
                }

                let market = marketplaceCoordinator.assemble(
                    ticker: next,
                    status: status,
                    mobileShield: shieldStatus
                )

                if now.timeIntervalSince(self.lastPurgeTime) >= 60 {
                    _ = try? purge.purgeExpired()
                    self.lastPurgeTime = now
                }

                let meetingSnap = meetings.snapshot()
                let habitSnap = habitCoordinator.snapshot(ticker: next)
                let calibrationSnap = calibration.snapshot()

                if next.spendableBalance != self.lastKnownBalance || now.timeIntervalSince(self.lastLedgerReloadTime) >= 30 {
                    self.cachedVault = (try? ledger.loadVault()) ?? .empty
                    self.cachedReconciliations = (try? ledger.allReconciliations()) ?? []
                    self.cachedTransactions = (try? ledger.allTransactions()) ?? []
                    self.lastKnownBalance = next.spendableBalance
                    self.lastLedgerReloadTime = now
                }

                let dash = CommandDashboardSnapshot.assemble(
                    ticker: next,
                    calibration: calibrationSnap,
                    vault: self.cachedVault,
                    reconciliations: self.cachedReconciliations,
                    transactions: self.cachedTransactions,
                    security: gatekeeper.snapshot(),
                    governance: habitGovernance.snapshot(),
                    emergencyDebtCredits: cache.unleviedIncidents().reduce(0) { $0 + $1.signedDebtCredits },
                    emergencyValveActive: status?.activePasses.contains { $0.kind == .emergency } == true,
                    amenityPrices: (try? habitGovernance.amenityPriceOverrides()) ?? [:],
                    blocklistRules: (try? habitGovernance.blocklistRules()) ?? [],
                    habits: habitSnap.habits
                )
                self.snapshot = next
                self.marketplace = market
                self.meeting = meetingSnap
                self.habits = habitSnap
                self.dashboard = dash
                self.publishCalibrationModeIfNeeded(calibrationSnap.enforcementMode)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func enrollSettings(password: String, confirmation: String, secret: String, totp: String) async {
        do {
            _ = try gatekeeper.enroll(
                password: password,
                passwordConfirmation: confirmation,
                totpSecret: secret,
                totpCode: totp
            )
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    func unlockSettings(password: String, totp: String) async {
        do {
            _ = try await gatekeeper.unlock(password: password, totp: totp)
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    func lockSettings() {
        gatekeeper.lockSettings()
        refreshDashboard()
    }

    func updateAmenityPrice(kind: AmenityKind, cost: Double) {
        do {
            _ = try habitGovernance.setAmenityPrice(kind, cost: cost)
            let next = (try? marketplaceCoordinator.engine.snapshot()) ?? snapshot
            marketplace = marketplaceCoordinator.assemble(
                ticker: next,
                status: nil,
                mobileShield: marketplace.mobileShield
            )
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    func addBlocklistRule(domain: String) {
        do {
            _ = try habitGovernance.addBlocklistSuffix(domain)
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    func removeBlocklistRule(domain: String) {
        do {
            try habitGovernance.removeBlocklistSuffix(domain)
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    func updateAlertRecipient(email: String) {
        do {
            _ = try gatekeeper.updateAlertRecipient(email)
        } catch {
            _ = error
        }
        refreshDashboard()
    }

    private func publishCalibrationModeIfNeeded(_ mode: EnforcementMode) {
        if lastPublishedMode == mode {
            return
        }
        Task {
            do {
                try await client.applyPolicy(
                    EnforcementPolicySnapshot(EnforcementPolicy(mode: mode))
                )
                await MainActor.run { [weak self] in
                    self?.lastPublishedMode = mode
                }
            } catch {
                // Leave lastPublishedMode unchanged so subsequent ticks retry,
                // especially Day 4 `.hard`.
            }
        }
    }

    private func refreshDashboard() {
        dashboard = CommandDashboardSnapshot.assemble(
            ticker: snapshot,
            calibration: calibration.snapshot(),
            vault: (try? ledger.loadVault()) ?? .empty,
            reconciliations: (try? ledger.allReconciliations()) ?? [],
            transactions: (try? ledger.allTransactions()) ?? [],
            security: gatekeeper.snapshot(),
            governance: habitGovernance.snapshot(),
            emergencyDebtCredits: incidentCache.unleviedIncidents().reduce(0) { $0 + $1.signedDebtCredits },
            emergencyValveActive: marketplace.mobileShield.passActive,
            amenityPrices: (try? habitGovernance.amenityPriceOverrides()) ?? [:],
            blocklistRules: (try? habitGovernance.blocklistRules()) ?? [],
            habits: habits.habits
        )
    }

    func purchase(_ kind: AmenityKind) {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        Task {
            defer { purchaseInFlight = false }
            do {
                try await marketplaceCoordinator.purchase(kind)
            } catch {
                _ = error
            }
            let next = (try? marketplaceCoordinator.engine.snapshot()) ?? snapshot
            let status = try? await client.queryStatus()
            let publication = await shield.publish(
                ticker: next,
                status: status,
                now: Date(),
                event: .focusTick
            )
            let market = marketplaceCoordinator.assemble(
                ticker: next,
                status: status,
                mobileShield: publication.status
            )
            snapshot = next
            marketplace = market
        }
    }

    func toggleFocus() {
        do {
            if snapshot.focusState == .active || snapshot.focusState == .pausedGrace {
                _ = try marketplaceCoordinator.engine.completeFocus()
            } else {
                _ = try marketplaceCoordinator.engine.startFocus()
            }
            if let next = try? marketplaceCoordinator.engine.snapshot() {
                snapshot = next
                marketplace = marketplaceCoordinator.assemble(
                    ticker: next,
                    status: nil,
                    mobileShield: marketplace.mobileShield
                )
            }
            refreshDashboard()
        } catch {
            _ = error
        }
    }

    func punchToggle() {
        do {
            _ = try meetings.togglePunch()
        } catch {
            _ = error
        }
        meeting = meetings.snapshot()
    }

    func submitMeeting() {
        Task {
            do {
                let record = try meetings.submit()
                meeting = meetings.snapshot()
                _ = try await auditor.auditFlash(meetingID: record.id)
            } catch {
                _ = error
            }
            refreshAfterAudit()
        }
    }

    func retryMeetingAudit() {
        guard let id = meetings.activeMeeting?.id ?? meeting.meetingID else { return }
        Task {
            do {
                _ = try await auditor.retryAudit(meetingID: id)
            } catch {
                _ = error
            }
            refreshAfterAudit()
        }
    }

    func appealMeeting(_ statement: String) {
        guard let id = meetings.activeMeeting?.id ?? meeting.meetingID else { return }
        Task {
            do {
                _ = try await auditor.appealToPro(meetingID: id, statement: statement)
            } catch {
                _ = error
            }
            refreshAfterAudit()
        }
    }

    private func refreshAfterAudit() {
        meeting = meetings.snapshot()
        if let next = try? marketplaceCoordinator.engine.snapshot() {
            snapshot = next
            marketplace = marketplaceCoordinator.assemble(
                ticker: next,
                status: nil,
                mobileShield: marketplace.mobileShield
            )
            habits = habitCoordinator.snapshot(ticker: next)
        }
        refreshDashboard()
    }

    func abandonMeeting() {
        do {
            _ = try meetings.abandon()
        } catch {
            _ = error
        }
        meeting = meetings.snapshot()
    }

    func importArtifact(kind: MeetingArtifactKind, url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            _ = try meetings.attach(kind: kind, from: url)
        } catch {
            _ = error
        }
        meeting = meetings.snapshot()
    }

    func completeHabit(_ id: UUID) {
        do {
            _ = try habitCoordinator.complete(habitID: id)
        } catch {
            _ = error
        }
        refreshHabits()
    }

    func createHabit(_ title: String, reward: Double, frequency: Int) {
        do {
            _ = try habitCoordinator.createHabit(
                title: title,
                rewardCredits: reward,
                dailyFrequencyLimit: frequency
            )
        } catch {
            _ = error
        }
        refreshHabits()
    }

    private func refreshHabits() {
        if let next = try? marketplaceCoordinator.engine.snapshot() {
            snapshot = next
            marketplace = marketplaceCoordinator.assemble(
                ticker: next,
                status: nil,
                mobileShield: marketplace.mobileShield
            )
            habits = habitCoordinator.snapshot(ticker: next)
        } else {
            habits = habitCoordinator.snapshot(ticker: snapshot)
        }
        refreshDashboard()
    }

    func triggerEmergencyValve() async {
        do {
            try await client.engageEmergencySafetyValve()
            refreshDashboard()
        } catch {
            _ = error
        }
    }

    deinit {
        timer?.cancel()
        client.invalidate()
    }
}

private final class TickCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight {
            return false
        }
        inFlight = true
        return true
    }

    func end() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}
