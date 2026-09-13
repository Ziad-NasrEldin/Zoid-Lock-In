import Foundation
import ZoidLockInCore

/// Serial economy worker. SQLite ticks never run on the main actor.
public final class EconomyTickCoordinator: @unchecked Sendable {
    public let engine: ExchangeEngine
    public let incidentCache: CachedEmergencyIncidentStore
    public let queueLabel: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var lastSnapshot: MenuBarTickerSnapshot

    public init(
        engine: ExchangeEngine,
        incidentCache: CachedEmergencyIncidentStore = CachedEmergencyIncidentStore(),
        queue: DispatchQueue = DispatchQueue(label: "zoidlockin.economy", qos: .userInitiated)
    ) {
        self.engine = engine
        self.incidentCache = incidentCache
        self.queue = queue
        self.queueLabel = "zoidlockin.economy"
        self.lastSnapshot = (try? engine.snapshot()) ?? .proof
    }

    /// Pulls daemon incidents, ticks the engine off the caller thread, then
    /// reports newly levied UUIDs so the client can notify the daemon.
    public func reconcileIncidentsAndTick(
        fetchIncidents: @escaping @Sendable () async throws -> [EmergencyIncidentRecord],
        markLevied: @escaping @Sendable (UUID) async throws -> Void
    ) async -> MenuBarTickerSnapshot {
        let incidents = (try? await fetchIncidents()) ?? []
        let snapshot = await tick(with: incidents)
        for id in incidentCache.takePendingLevyMarks() {
            try? await markLevied(id)
        }
        return snapshot
    }

    public func tick(with incidents: [EmergencyIncidentRecord] = []) async -> MenuBarTickerSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.incidentCache.replaceUnlevied(incidents)
                let snapshot: MenuBarTickerSnapshot
                do {
                    snapshot = try self.engine.tick()
                } catch {
                    snapshot = (try? self.engine.snapshot()) ?? self.lastSnapshot
                }
                self.lock.lock()
                self.lastSnapshot = snapshot
                self.lock.unlock()
                continuation.resume(returning: snapshot)
            }
        }
    }
}
