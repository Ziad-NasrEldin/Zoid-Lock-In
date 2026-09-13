import AppKit
import SwiftUI
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInIPC

@main
enum ZoidLockInAppEntry {
    static func main() {
        if CommandLine.arguments.contains("--render-menubar-proof") {
            renderProofAndExit()
            return
        }
        ZoidLockInMenuBarApp.main()
    }

    @MainActor
    private static func renderProofAndExit() {
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
}

struct ZoidLockInMenuBarApp: App {
    @StateObject private var session = MenuBarSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarTickerView(snapshot: session.snapshot)
        } label: {
            MenuBarTickerLabel(snapshot: session.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuBarSession: ObservableObject {
    @Published var snapshot: MenuBarTickerSnapshot

    private let coordinator: EconomyTickCoordinator
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

        self.coordinator = coordinator
        self.client = client
        self.economyQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
        self.snapshot = (try? engine.snapshot()) ?? .proof

        let timer = DispatchSource.makeTimerSource(queue: economyQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [coordinator, client] in
            Task {
                let next = await coordinator.reconcileIncidentsAndTick(
                    fetchIncidents: { try await client.queryUnleviedEmergencyIncidents() },
                    markLevied: { try await client.markEmergencyIncidentLevied(uuid: $0) }
                )
                await MainActor.run { [weak self] in
                    self?.snapshot = next
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        client.invalidate()
    }
}
