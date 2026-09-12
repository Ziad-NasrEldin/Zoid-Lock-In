import Foundation
import ZoidLockInCore
import ZoidLockInIPC

/// Privileged enforcement daemon. Owns the process sentinel, monotonic pass
/// expiry, heartbeat fail-closed watchdog, and authenticated XPC listener.
///
/// Does **not** instantiate `ContentFilterProvider`; that type lives in
/// `ZoidLockInFilterExtension`.
public final class EnforcementDaemon: @unchecked Sendable, ZoidLockInEnforcementServicing, EmergencySafetyValveDispatching {
    public let configuration: DaemonConfiguration
    public let registrar: DaemonServiceRegistrar
    public let processSentinel: ProcessSentinel
    public let clock: any MonotonicTimeProviding
    public let gatekeeper: XPCAuditTokenGatekeeper
    public let auditLog: XPCConnectionAuditLog

    private let lock = NSLock()
    private var basePolicy: EnforcementPolicy
    private var effectivePolicy: EnforcementPolicy
    private var passController = DaemonPassController()
    private var heartbeatMonitor = HeartbeatMonitor()
    private var usedNonces: Set<String> = []
    private var liveConnectionCount = 0
    private var isStarted = false
    private var watchdog: DispatchSourceTimer?
    private var machListener: NSXPCListener?
    private var listenerDelegate: EnforcementXPCListener?

    public init(
        configuration: DaemonConfiguration = DaemonConfiguration(),
        policy: EnforcementPolicy = .lockedDown,
        processSentinel: ProcessSentinel? = nil,
        clock: any MonotonicTimeProviding = MachAbsoluteTimeClock(),
        gatekeeper: XPCAuditTokenGatekeeper = XPCAuditTokenGatekeeper(),
        auditLog: XPCConnectionAuditLog = XPCConnectionAuditLog()
    ) {
        self.configuration = configuration
        self.registrar = DaemonServiceRegistrar(configuration: configuration)
        self.basePolicy = policy
        self.effectivePolicy = policy
        self.clock = clock
        self.gatekeeper = gatekeeper
        self.auditLog = auditLog
        self.processSentinel = processSentinel ?? ProcessSentinel(
            matcher: policy.processMatcher,
            scanInterval: policy.processScanIntervalSeconds,
            mode: policy.mode
        )
        self.processSentinel.apply(policy)
    }

    public var currentPolicy: EnforcementPolicy {
        withLock { effectivePolicy }
    }

    public var activePass: DaemonLocalPass? {
        withLock { passController.active }
    }

    /// Direct policy mutation used at boot and by tests. Not an XPC entry point.
    public func applyPolicy(_ policy: EnforcementPolicy) {
        withLock { basePolicy = policy }
        publishEffectivePolicy(at: clock.nowSeconds())
    }

    public func applyPolicy(_ snapshot: EnforcementPolicySnapshot) async throws {
        var incoming = snapshot.makePolicy()
        incoming.mode = .hard
        applyPolicy(incoming)
    }

    public func openPass(kind: PassKind, durationSeconds: Int, nonce: String) async throws {
        let replayed = withLock { () -> Bool in
            if usedNonces.contains(nonce) {
                return true
            }
            usedNonces.insert(nonce)
            return false
        }
        if replayed {
            throw ZoidLockInXPCError.make(4, message: "Replay nonce rejected")
        }

        if kind == .emergency {
            try await engageEmergencySafetyValve()
            return
        }

        let now = clock.nowSeconds()
        withLock {
            passController.open(kind: kind, durationSeconds: TimeInterval(durationSeconds), at: now)
        }
        publishEffectivePolicy(at: now)
    }

    public func revokePass(kind: PassKind) async throws {
        let now = clock.nowSeconds()
        withLock {
            if passController.active?.kind == kind {
                passController.revoke()
            }
        }
        publishEffectivePolicy(at: now)
    }

    public func queryStatus() async throws -> EnforcementStatus {
        let now = clock.nowSeconds()
        publishEffectivePolicy(at: now)

        return withLock {
            if let pass = passController.active, pass.isActive(at: now) {
                return EnforcementStatus(
                    mode: effectivePolicy.mode,
                    isLockedDown: false,
                    activePassKind: pass.kind,
                    remainingPassSeconds: Int(pass.remainingSeconds(at: now).rounded(.towardZero))
                )
            }
            return EnforcementStatus(
                mode: effectivePolicy.mode,
                isLockedDown: true,
                activePassKind: nil,
                remainingPassSeconds: 0
            )
        }
    }

    public func engageEmergencySafetyValve() async throws {
        let now = clock.nowSeconds()
        withLock { passController.engageEmergency(at: now) }
        publishEffectivePolicy(at: now)
    }

    public func heartbeat() async throws {
        let now = clock.nowSeconds()
        withLock { heartbeatMonitor.recordBeat(at: now) }
        publishEffectivePolicy(at: now)
    }

    /// Gatekeeper entry used by the NSXPC listener and by unit tests.
    @discardableResult
    public func admitIncomingConnection(auditToken: Data, pid: pid_t, at time: TimeInterval? = nil) -> Bool {
        let decision = gatekeeper.evaluate(auditToken: auditToken, pid: pid)
        let now = time ?? clock.nowSeconds()
        auditLog.record(
            XPCConnectionAuditEvent(
                accepted: decision.accepted,
                pid: pid,
                signingIdentifier: decision.identity?.signingIdentifier,
                teamIdentifier: decision.identity?.teamIdentifier,
                reason: decision.rejection.map { String(describing: $0) } ?? "accepted",
                atSeconds: now
            )
        )
        return decision.accepted
    }

    public func noteClientConnected(at time: TimeInterval? = nil) {
        let now = time ?? clock.nowSeconds()
        withLock {
            liveConnectionCount += 1
            heartbeatMonitor.noteAcceptedConnection(at: now)
        }
    }

    public func noteClientDisconnected(at time: TimeInterval? = nil) {
        let now = time ?? clock.nowSeconds()
        let remaining = withLock { () -> Int in
            liveConnectionCount = max(0, liveConnectionCount - 1)
            if liveConnectionCount == 0 {
                heartbeatMonitor.noteConnectionLost(at: now)
            }
            return liveConnectionCount
        }
        _ = remaining
        evaluateWatchdogs(at: now)
    }

    public func evaluateWatchdogs(at time: TimeInterval? = nil) {
        publishEffectivePolicy(at: time ?? clock.nowSeconds())
    }

    /// Starts the process sentinel and monotonic watchdogs. Network Extension
    /// activation is owned by the unprivileged app via `ContentFilterActivation`.
    public func start() {
        let shouldStart = withLock { () -> Bool in
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard shouldStart else { return }
        processSentinel.start()
        startWatchdog()
    }

    public func stop() {
        let shouldStop = withLock { () -> Bool in
            guard isStarted else { return false }
            isStarted = false
            watchdog?.cancel()
            watchdog = nil
            machListener?.invalidate()
            machListener = nil
            listenerDelegate = nil
            return true
        }
        guard shouldStop else { return }
        processSentinel.stop()
    }

    public func startMachServiceListener(listener: NSXPCListener? = nil) {
        let machListener = listener ?? NSXPCListener(
            machServiceName: ZoidLockInIdentity.enforcementMachServiceName
        )
        let delegate = EnforcementXPCListener(daemon: self)
        withLock {
            self.listenerDelegate = delegate
            self.machListener = machListener
        }
        machListener.delegate = delegate
        machListener.resume()
    }

    public var launchDaemonPropertyList: [String: Any] {
        configuration.propertyList
    }

    public var launchDaemonPropertyListXML: String {
        configuration.propertyListXML()
    }

    public var isEmergencyPassActive: Bool {
        withLock { passController.isEmergencyPassActive(at: clock.nowSeconds()) }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.evaluateWatchdogs()
        }
        withLock { watchdog = timer }
        timer.resume()
    }

    private func publishEffectivePolicy(at time: TimeInterval) {
        let next = withLock { () -> EnforcementPolicy in
            passController.expireIfNeeded(at: time)

            let passActive = passController.active?.isActive(at: time) == true
            if heartbeatMonitor.hasTimedOut(at: time), !passActive {
                basePolicy = .lockedDown
            }

            var policy = basePolicy
            if passActive {
                policy = basePolicy.relaxingForActivePass()
            } else {
                policy.mode = .hard
            }
            effectivePolicy = policy
            return policy
        }
        processSentinel.apply(next)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
