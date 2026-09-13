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
}

struct ZoidLockInMenuBarApp: App {
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        MenuBarExtra {
            MarketplacePopoverView(
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
    private let client: XPCEnforcementClient
    private let economyQueue: DispatchQueue
    nonisolated(unsafe) private var timer: DispatchSourceTimer?

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
        let marketplaceCoordinator = MarketplaceCoordinator(
            engine: engine,
            issuer: AmenityVoucherIssuer(),
            redeemer: client
        )

        self.coordinator = coordinator
        self.marketplaceCoordinator = marketplaceCoordinator
        self.client = client
        self.economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
        let initial = (try? engine.snapshot()) ?? .proof
        self.snapshot = initial
        self.marketplace = MarketplaceSnapshot.assemble(ticker: initial)

        let timer = DispatchSource.makeTimerSource(queue: economyQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [coordinator, client, marketplaceCoordinator] in
            Task {
                let next = await coordinator.reconcileIncidentsAndTick(
                    fetchIncidents: { try await client.queryUnleviedEmergencyIncidents() },
                    markLevied: { try await client.markEmergencyIncidentLevied(uuid: $0) }
                )
                let status = try? await client.queryStatus()
                let market = marketplaceCoordinator.assemble(ticker: next, status: status)
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
        Task {
            do {
                try await marketplaceCoordinator.purchase(kind)
            } catch {
                _ = error
            }
            let next = (try? marketplaceCoordinator.engine.snapshot()) ?? snapshot
            let status = try? await client.queryStatus()
            let market = marketplaceCoordinator.assemble(ticker: next, status: status)
            snapshot = next
            marketplace = market
        }
    }

    deinit {
        timer?.cancel()
        client.invalidate()
    }
}
