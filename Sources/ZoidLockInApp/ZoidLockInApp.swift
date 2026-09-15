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

struct ZoidLockInMenuBarApp: App {
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarCompanionRoot(session: session)
        } label: {
            MenuBarTickerLabel(snapshot: session.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Command Dashboard", id: "command-dashboard") {
            CommandDashboardContainer(session: session)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarCompanionRoot: View {
    @ObservedObject var session: MenuBarSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarExtraView(
            snapshot: session.marketplace,
            onPurchase: session.purchase,
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
            }
        )
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
    private let economyQueue: DispatchQueue
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    private var purchaseInFlight = false
    private var lastPublishedMode: EnforcementMode?

    init() {
        let ledger = (try? SQLiteEconomicLedger.default()) ?? (try? SQLiteEconomicLedger())
        let resolved = ledger ?? (try! SQLiteEconomicLedger())
        let cache = CachedEmergencyIncidentStore()
        let timeTravel = TimeTravelGuard()
        let fallbackDirectory = resolved.fileURL?.deletingLastPathComponent()
            ?? EncryptedStateStore.defaultApplicationSupportDirectory()
        let habitGovernance = GovernanceLockCoordinator(
            store: resolved,
            clock: MachContinuousTimeClock(),
            wallClock: SystemWallClock(),
            timeTravel: timeTravel,
            keyProvider: KeychainGovernanceKeyProvider(),
            replicaSealStore: FileGovernanceSealStore(fallbackDirectory: fallbackDirectory)
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
            timeZone: pinnedTimeZone
        )
        habitGovernance.onBlocklistChanged = { rules in
            let snapshot = EnforcementPolicySnapshot(
                EnforcementPolicy(domainRules: rules, mode: calibration.enforcementMode())
            )
            Task {
                try? await client.applyPolicy(snapshot)
            }
        }
        let gatekeeper = SecurityGatekeeper(
            keychain: ZoidLockInKeychain(),
            mail: AlertMailService(
                configuration: AlertMailConfiguration(recipient: SecurityGatekeeper.defaultRecipient)
            )
        )
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
        self.economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
        let initial = (try? engine.snapshot()) ?? .proof
        self.snapshot = initial
        self.marketplace = MarketplaceSnapshot.assemble(ticker: initial)
        self.meeting = meetings.snapshot()
        self.habits = habitCoordinator.snapshot(ticker: initial)
        self.dashboard = CommandDashboardSnapshot.assemble(
            ticker: initial,
            calibration: calibration.snapshot(),
            vault: (try? resolved.loadVault()) ?? .empty,
            reconciliations: (try? resolved.allReconciliations()) ?? [],
            transactions: (try? resolved.allTransactions()) ?? [],
            security: gatekeeper.snapshot(),
            governance: habitGovernance.snapshot()
        )
        lastPublishedMode = calibration.enforcementMode()
        Task {
            try? await client.applyPolicy(
                EnforcementPolicySnapshot(
                    EnforcementPolicy(mode: calibration.enforcementMode())
                )
            )
        }

        let coalescer = TickCoalescer()
        let timer = DispatchSource.makeTimerSource(queue: economyQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [coordinator, client, marketplaceCoordinator, shield, meetings, purge, habitCoordinator, calibration, habitGovernance, ledger = resolved, cache, gatekeeper] in
            guard coalescer.begin() else { return }
            Task {
                defer { coalescer.end() }
                let next = await coordinator.reconcileIncidentsAndTick(
                    fetchIncidents: { try await client.queryUnleviedEmergencyIncidents() },
                    markLevied: { try await client.markEmergencyIncidentLevied(uuid: $0) }
                )
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
                _ = try? purge.purgeExpired()
                let meetingSnap = meetings.snapshot()
                let habitSnap = habitCoordinator.snapshot(ticker: next)
                let calibrationSnap = calibration.snapshot()
                let dash = CommandDashboardSnapshot.assemble(
                    ticker: next,
                    calibration: calibrationSnap,
                    vault: (try? ledger.loadVault()) ?? .empty,
                    reconciliations: (try? ledger.allReconciliations()) ?? [],
                    transactions: (try? ledger.allTransactions()) ?? [],
                    security: gatekeeper.snapshot(),
                    governance: habitGovernance.snapshot(),
                    emergencyDebtCredits: cache.unleviedIncidents().reduce(0) { $0 + $1.signedDebtCredits },
                    emergencyValveActive: status?.activePasses.contains { $0.kind == .emergency } == true
                )
                await MainActor.run { [weak self] in
                    self?.snapshot = next
                    self?.marketplace = market
                    self?.meeting = meetingSnap
                    self?.habits = habitSnap
                    self?.dashboard = dash
                    self?.publishCalibrationModeIfNeeded(calibrationSnap.enforcementMode)
                }
            }
        }
        self.timer = timer
        timer.resume()
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

    private func publishCalibrationModeIfNeeded(_ mode: EnforcementMode) {
        guard lastPublishedMode != mode else { return }
        lastPublishedMode = mode
        Task {
            try? await client.applyPolicy(
                EnforcementPolicySnapshot(EnforcementPolicy(mode: mode))
            )
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
            emergencyValveActive: marketplace.mobileShield.passActive
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
