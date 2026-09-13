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
}

struct ZoidLockInMenuBarApp: App {
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarExtraView(
                snapshot: session.marketplace,
                onPurchase: session.purchase
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

    private let coordinator: EconomyTickCoordinator
    private let marketplaceCoordinator: MarketplaceCoordinator
    private let shield: MobileShieldCoordinator
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

        self.coordinator = coordinator
        self.marketplaceCoordinator = marketplaceCoordinator
        self.shield = shield
        self.client = client
        self.economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
        let initial = (try? engine.snapshot()) ?? .proof
        self.snapshot = initial
        self.marketplace = MarketplaceSnapshot.assemble(ticker: initial)

        let coalescer = TickCoalescer()
        let timer = DispatchSource.makeTimerSource(queue: economyQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [coordinator, client, marketplaceCoordinator, shield] in
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
                await MainActor.run { [weak self] in
                    self?.snapshot = next
                    self?.marketplace = market
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
