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
}

struct ZoidLockInMenuBarApp: App {
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarExtraView(
                snapshot: session.marketplace,
                onPurchase: session.purchase,
                meeting: session.meeting,
                onPunchToggle: session.punchToggle,
                onSubmitMeeting: session.submitMeeting,
                onImportArtifact: session.importArtifact
            )
        } label: {
            MenuBarTickerLabel(snapshot: session.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuBarSession: ObservableObject {
    @Published var snapshot: MenuBarTickerSnapshot
    @Published var marketplace: MarketplaceSnapshot
    @Published var meeting: OfflineMeetingSnapshot

    private let coordinator: EconomyTickCoordinator
    private let marketplaceCoordinator: MarketplaceCoordinator
    private let shield: MobileShieldCoordinator
    private let meetings: OfflineSessionCoordinator
    private let purge: MeetingArtifactPurgeScheduler
    private let client: XPCEnforcementClient
    private let economyQueue: DispatchQueue
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    private var purchaseInFlight = false

    init() {
        let ledger = (try? SQLiteEconomicLedger.default()) ?? (try? SQLiteEconomicLedger())
        let resolved = ledger ?? (try! SQLiteEconomicLedger())
        let cache = CachedEmergencyIncidentStore()
        let engine = ExchangeEngine(
            ledger: resolved,
            incidentStore: cache,
            clock: MachContinuousTimeClock(),
            focusClock: MachUptimeClock()
        )
        let coordinator = EconomyTickCoordinator(engine: engine, incidentCache: cache)
        let client = XPCEnforcementClient()
        client.resume()
        client.startHeartbeatLoop()
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
            wallClock: SystemWallClock()
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
        self.purge = purge
        self.client = client
        self.economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
        let initial = (try? engine.snapshot()) ?? .proof
        self.snapshot = initial
        self.marketplace = MarketplaceSnapshot.assemble(ticker: initial)
        self.meeting = meetings.snapshot()

        let coalescer = TickCoalescer()
        let timer = DispatchSource.makeTimerSource(queue: economyQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [coordinator, client, marketplaceCoordinator, shield, meetings, purge] in
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
                await MainActor.run { [weak self] in
                    self?.snapshot = next
                    self?.marketplace = market
                    self?.meeting = meetingSnap
                }
            }
        }
        self.timer = timer
        timer.resume()
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
        do {
            _ = try meetings.submit()
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
