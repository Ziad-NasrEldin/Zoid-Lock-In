import Foundation
import ZoidLockInCore

/// User-space NSXPC client for `com.mavoid.zoidlockin.enforcement`.
///
/// Pins the daemon with a Team-ID-pinned designated requirement so a fake Mach
/// service cannot impersonate the helper.
public final class XPCEnforcementClient: NSObject, ZoidLockInEnforcementServicing, EmergencySafetyValveDispatching, EnforcementStatusQuerying, @unchecked Sendable {
    public let machServiceName: String
    public let daemonCodeSigningRequirement: String
    public let heartbeatIntervalSeconds: TimeInterval

    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?

    public init(
        machServiceName: String = ZoidLockInIdentity.enforcementMachServiceName,
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier(),
        heartbeatIntervalSeconds: TimeInterval = 1.0
    ) {
        self.machServiceName = machServiceName
        self.daemonCodeSigningRequirement = ZoidLockInIdentity.xpcDaemonRequirement(teamID: teamID)
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.connection = NSXPCConnection(machServiceName: machServiceName)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: ZoidLockInEnforcementXPC.self)
    }

    public func resume() {
        connection.setCodeSigningRequirement(daemonCodeSigningRequirement)
        connection.resume()
    }

    public func invalidate() {
        stopHeartbeatLoop()
        connection.invalidate()
    }

    public func startHeartbeatLoop() {
        lock.lock()
        defer { lock.unlock() }
        guard heartbeatTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now(),
            repeating: heartbeatIntervalSeconds,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                try? await self?.heartbeat()
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    public func stopHeartbeatLoop() {
        lock.lock()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        lock.unlock()
    }

    public func applyPolicy(_ snapshot: EnforcementPolicySnapshot) async throws {
        let data = try JSONEncoder().encode(snapshot)
        try await invoke { proxy, reply in
            proxy.applyPolicy(data, withReply: reply)
        }
    }

    public func openPass(kind: PassKind, durationSeconds: Int, nonce: String) async throws {
        try await invoke { proxy, reply in
            proxy.openPassWithKind(
                kind.rawValue,
                durationSeconds: durationSeconds,
                nonce: nonce,
                withReply: reply
            )
        }
    }

    public func redeemAmenityVoucher(_ voucher: AmenityPassVoucher) async throws {
        let data = try JSONEncoder().encode(voucher)
        try await invoke { proxy, reply in
            proxy.redeemAmenityVoucher(data, withReply: reply)
        }
    }

    public func revokePass(kind: PassKind) async throws {
        try await invoke { proxy, reply in
            proxy.revokePassWithKind(kind.rawValue, withReply: reply)
        }
    }

    public func queryStatus() async throws -> EnforcementStatus {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = remoteProxy(continuation: continuation) else { return }
            proxy.queryStatus { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(
                        throwing: ZoidLockInXPCError.make(3, message: "Missing status payload")
                    )
                    return
                }
                do {
                    let status = try JSONDecoder().decode(EnforcementStatus.self, from: data)
                    continuation.resume(returning: status)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func engageEmergencySafetyValve() async throws {
        try await invoke { proxy, reply in
            proxy.engageEmergencySafetyValve(withReply: reply)
        }
    }

    public func heartbeat() async throws {
        try await invoke { proxy, reply in
            proxy.heartbeat(withReply: reply)
        }
    }

    public func queryUnleviedEmergencyIncidents() async throws -> [EmergencyIncidentRecord] {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = remoteProxy(continuation: continuation) else { return }
            proxy.queryUnleviedEmergencyIncidents { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(
                        throwing: ZoidLockInXPCError.make(3, message: "Missing incident payload")
                    )
                    return
                }
                do {
                    let records = try JSONDecoder().decode([EmergencyIncidentRecord].self, from: data)
                    continuation.resume(returning: records)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func markEmergencyIncidentLevied(uuid: UUID) async throws {
        try await invoke { proxy, reply in
            proxy.markEmergencyIncidentLeviedWithUUID(uuid.uuidString, withReply: reply)
        }
    }

    private func invoke(
        _ body: @escaping (any ZoidLockInEnforcementXPC, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = remoteProxy(continuation: continuation) else { return }
            body(proxy) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func remoteProxy<T>(
        continuation: CheckedContinuation<T, Error>
    ) -> (any ZoidLockInEnforcementXPC)? {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            continuation.resume(throwing: error)
        } as? any ZoidLockInEnforcementXPC

        if proxy == nil {
            continuation.resume(
                throwing: ZoidLockInXPCError.make(2, message: "Remote proxy unavailable")
            )
        }
        return proxy
    }

    deinit {
        stopHeartbeatLoop()
        connection.invalidate()
    }
}
