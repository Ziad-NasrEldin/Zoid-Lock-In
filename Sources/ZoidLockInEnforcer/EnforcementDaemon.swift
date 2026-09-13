import Foundation
import ZoidLockInCore
import ZoidLockInIPC

/// Privileged enforcement daemon. Owns the process sentinel, continuous
/// monotonic pass expiry, heartbeat fail-closed watchdog, durable emergency
/// incident log, and authenticated XPC listener.
///
/// Does **not** instantiate `ContentFilterProvider`; that type lives in
/// `ZoidLockInFilterExtension`. The daemon publishes filter status through
/// `FilterPolicyHub` (and optionally a file store) for query-only consumption.
public final class EnforcementDaemon: @unchecked Sendable, ZoidLockInEnforcementServicing, EmergencySafetyValveDispatching, FilterEnforcementStatusReading, EnforcementStatusQuerying {
    public let configuration: DaemonConfiguration
    public let registrar: DaemonServiceRegistrar
    public let processSentinel: ProcessSentinel
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let gatekeeper: XPCAuditTokenGatekeeper
    public let auditLog: XPCConnectionAuditLog
    public let filterPolicyHub: FilterPolicyHub
    public let incidentStore: any EmergencyIncidentStoring
    public let redemptionJournal: any RedemptionJournaling
    public let bootSessionUUID: String
    public let voucherVerifier: AmenityVoucherVerifier
    public let civilClock: LocalCivilClock

    private let filterStatusSink: (any FilterEnforcementStatusPublishing)?
    private let lock = NSLock()
    private var basePolicy: EnforcementPolicy
    private var effectivePolicy: EnforcementPolicy
    private var passController = DaemonPassController()
    private var heartbeatMonitor = HeartbeatMonitor()
    private var usedNonces: Set<String> = []
    private var usedTransactionIDs: Set<UUID> = []
    private var liveConnectionCount = 0
    private var isStarted = false
    private var watchdog: DispatchSourceTimer?
    private var machListener: NSXPCListener?
    private var listenerDelegate: EnforcementXPCListener?
    private var lastObservedMonotonicSeconds: TimeInterval?

    public init(
        configuration: DaemonConfiguration = DaemonConfiguration(),
        policy: EnforcementPolicy = .lockedDown,
        processSentinel: ProcessSentinel? = nil,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        gatekeeper: XPCAuditTokenGatekeeper = XPCAuditTokenGatekeeper(),
        auditLog: XPCConnectionAuditLog = XPCConnectionAuditLog(),
        filterPolicyHub: FilterPolicyHub = FilterPolicyHub(),
        incidentStore: (any EmergencyIncidentStoring)? = nil,
        filterStatusSink: (any FilterEnforcementStatusPublishing)? = nil,
        bootSessionUUID: String = BootSession.currentUUID(),
        storageDirectory: URL? = nil,
        voucherVerifier: AmenityVoucherVerifier = AmenityVoucherVerifier(),
        redemptionJournal: (any RedemptionJournaling)? = nil,
        civilClock: LocalCivilClock? = nil
    ) {
        let directory = storageDirectory ?? FileEmergencyIncidentStore.makeIsolatedDirectory()
        self.configuration = configuration
        self.registrar = DaemonServiceRegistrar(configuration: configuration)
        self.basePolicy = policy
        self.effectivePolicy = policy
        self.clock = clock
        self.wallClock = wallClock
        self.gatekeeper = gatekeeper
        self.auditLog = auditLog
        self.filterPolicyHub = filterPolicyHub
        self.incidentStore = incidentStore ?? FileEmergencyIncidentStore(directory: directory)
        self.redemptionJournal = redemptionJournal ?? FileRedemptionJournal(directory: directory)
        self.filterStatusSink = filterStatusSink
        self.bootSessionUUID = bootSessionUUID
        self.voucherVerifier = voucherVerifier
        self.civilClock = civilClock ?? LocalCivilClock(timeZone: .current)
        self.processSentinel = processSentinel ?? ProcessSentinel(
            matcher: policy.processMatcher,
            scanInterval: policy.processScanIntervalSeconds,
            mode: policy.mode
        )
        self.processSentinel.apply(policy)
        restoreCooldownFromIncidents()
        restoreAmenityPassesFromJournal()
        publishEffectivePolicy(at: clock.nowSeconds())
    }

    public var currentPolicy: EnforcementPolicy {
        withLock { effectivePolicy }
    }

    public var activePass: DaemonLocalPass? {
        withLock { passController.active }
    }

    public func currentFilterSnapshot() -> FilterEnforcementSnapshot {
        let now = clock.nowSeconds()
        publishEffectivePolicy(at: now)
        return filterPolicyHub.currentFilterSnapshot()
    }

    public func incidents() -> [EmergencyIncidentRecord] {
        incidentStore.allIncidents()
    }

    public func queryUnleviedEmergencyIncidents() async throws -> [EmergencyIncidentRecord] {
        incidentStore.unleviedIncidents()
    }

    public func markEmergencyIncidentLevied(uuid: UUID) async throws {
        try incidentStore.markLevied(id: uuid)
    }

    /// Installs a kind-scoped daemon-local pass without voucher verification.
    /// Not an XPC entry; amenity `openPass` still throws `amenityPassRequiresVoucher`.
    /// Concurrent kinds are stored independently and do not clobber each other.
    public func commitKindScopedPass(kind: PassKind, durationSeconds: TimeInterval) {
        let now = clock.nowSeconds()
        withLock {
            passController.install(kind: kind, durationSeconds: durationSeconds, at: now)
        }
        publishEffectivePolicy(at: now)
    }

    /// Direct policy mutation used at boot and by tests. Not an XPC entry point.
    public func applyPolicy(_ policy: EnforcementPolicy) {
        withLock { basePolicy = policy }
        publishEffectivePolicy(at: clock.nowSeconds())
    }

    public func applyPolicy(_ snapshot: EnforcementPolicySnapshot) async throws {
        let incoming = try snapshot.validatedPolicy()
        applyPolicy(incoming)
    }

    public func openPass(kind: PassKind, durationSeconds: Int, nonce: String) async throws {
        _ = durationSeconds
        if kind != .emergency {
            throw EnforcementControlError.amenityPassRequiresVoucher
        }

        let replayed = withLock { () -> Bool in
            if usedNonces.contains(nonce) {
                return true
            }
            usedNonces.insert(nonce)
            return false
        }
        if replayed {
            throw EnforcementControlError.replayNonceRejected
        }

        try await engageEmergencySafetyValve()
    }

    public func redeemAmenityVoucher(_ voucher: AmenityPassVoucher) async throws {
        let wallNow = wallClock.now()
        let claims: AmenityPassClaims
        do {
            claims = try voucherVerifier.verify(voucher, now: wallNow)
        } catch {
            throw EnforcementControlError.invalidAmenityVoucher(
                error.localizedDescription
            )
        }

        let now = clock.nowSeconds()
        try withLock {
            if usedNonces.contains(claims.nonce)
                || usedTransactionIDs.contains(claims.transactionID)
                || redemptionJournal.contains(nonce: claims.nonce)
                || redemptionJournal.contains(transactionID: claims.transactionID) {
                throw EnforcementControlError.replayNonceRejected
            }

            let duration = try clippedAmenityDurationLocked(
                kind: claims.kind,
                catalogSeconds: TimeInterval(claims.durationSeconds),
                at: wallNow
            )

            let entry = RedemptionJournalEntry(
                nonce: claims.nonce,
                transactionID: claims.transactionID,
                kind: claims.kind,
                monotonicStart: now,
                durationSeconds: duration,
                bootUUID: bootSessionUUID,
                issuedAt: claims.issuedAt
            )
            try redemptionJournal.record(entry)
            usedNonces.insert(claims.nonce)
            usedTransactionIDs.insert(claims.transactionID)
            passController.install(
                kind: claims.kind,
                durationSeconds: duration,
                at: now
            )
        }
        publishEffectivePolicy(at: now)
    }

    public func revokePass(kind: PassKind) async throws {
        let now = clock.nowSeconds()
        withLock {
            passController.revoke(kind: kind)
        }
        publishEffectivePolicy(at: now)
    }

    public func queryStatus() async throws -> EnforcementStatus {
        let snapshot = currentFilterSnapshot()
        return EnforcementStatus(
            mode: snapshot.enforcementPolicy.mode,
            isLockedDown: snapshot.isLockedDown,
            activePassKind: snapshot.activePassKind,
            remainingPassSeconds: snapshot.remainingPassSeconds,
            activePasses: snapshot.activePasses
        )
    }

    public func engageEmergencySafetyValve() async throws {
        let now = clock.nowSeconds()
        let utc = wallClock.now()
        let boot = bootSessionUUID

        try withLock { () throws in
            try passController.expireIfNeededThenEnsureEmergencyAllowed(
                at: now,
                utcNow: utc,
                bootSessionUUID: boot
            )
            let incident = EmergencyIncidentRecord.emergency(
                monotonicStartedAtSeconds: now,
                utcTimestamp: utc,
                bootSessionUUID: boot
            )
            try incidentStore.append(incident)
            passController.commitEmergency(
                at: now,
                utcNow: utc,
                bootSessionUUID: boot
            )
        }
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
        withLock {
            liveConnectionCount = max(0, liveConnectionCount - 1)
            if liveConnectionCount == 0 {
                heartbeatMonitor.noteConnectionLost(at: now)
            }
        }
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

    private func restoreAmenityPassesFromJournal() {
        let now = clock.nowSeconds()
        let wallNow = wallClock.now()
        let boot = bootSessionUUID
        let inCurfew = civilClock.isCurfew(wallNow)
        for entry in redemptionJournal.allEntries() {
            usedNonces.insert(entry.nonce)
            usedTransactionIDs.insert(entry.transactionID)
            guard entry.isRestorable(bootUUID: boot, at: now) else {
                continue
            }
            if entry.kind.isCurfewSensitive && inCurfew {
                continue
            }
            passController.install(
                kind: entry.kind,
                durationSeconds: entry.durationSeconds,
                at: entry.monotonicStart
            )
        }
    }

    private func clippedAmenityDurationLocked(
        kind: PassKind,
        catalogSeconds: TimeInterval,
        at wallNow: Date
    ) throws -> TimeInterval {
        guard kind.isCurfewSensitive else {
            return catalogSeconds
        }
        if civilClock.isCurfew(wallNow) {
            throw EnforcementControlError.curfewActive
        }
        let remaining = civilClock.secondsUntilCurfew(wallNow)
        let clipped = DaemonPassController.clippedDuration(
            kind: kind,
            catalogSeconds: catalogSeconds,
            secondsUntilCurfew: remaining
        )
        if clipped < 1 {
            throw EnforcementControlError.curfewActive
        }
        return clipped
    }

    private func restoreCooldownFromIncidents() {
        let incidents = incidentStore.allIncidents()
        guard let last = incidents.last(where: { $0.kind == .emergency }) else {
            return
        }
        passController.restoreCooldown(
            startedAt: last.monotonicStartedAtSeconds,
            utc: last.utcTimestamp,
            bootSessionUUID: last.bootSessionUUID
        )
    }

    private func publishEffectivePolicy(at time: TimeInterval) {
        let next = withLock { () -> (EnforcementPolicy, FilterEnforcementSnapshot, Set<PassKind>) in
            let clockNow = clock.nowSeconds()
            if let last = lastObservedMonotonicSeconds, clockNow + 0.000_001 < last {
                passController.revoke()
                basePolicy = .lockedDown
            } else {
                lastObservedMonotonicSeconds = clockNow
            }

            passController.expireIfNeeded(at: time)
            if civilClock.isCurfew(wallClock.now()) {
                passController.revokeCurfewSensitive()
            }

            let live = passController.activePasses(at: time)
            let kinds = Set(live.keys)
            let passActive = !kinds.isEmpty
            if heartbeatMonitor.hasTimedOut(at: time), !passActive {
                basePolicy = .lockedDown
            }

            var policy = basePolicy
            if passActive {
                policy = basePolicy.overlay(for: kinds)
            } else {
                policy.mode = .hard
            }
            effectivePolicy = policy

            let primary = passController.primaryPass(at: time)
            let remaining = Int(primary?.remainingSeconds(at: time).rounded(.towardZero) ?? 0)
            let passStatuses = live.map { kind, pass in
                ActivePassStatus(
                    kind: kind,
                    remainingSeconds: Int(pass.remainingSeconds(at: time).rounded(.towardZero))
                )
            }
            let snapshot = FilterEnforcementSnapshot(
                enforcementPolicy: policy,
                isPassActive: passActive,
                activePassKind: primary?.kind,
                remainingPassSeconds: remaining,
                isLockedDown: !passActive,
                activePasses: passStatuses
            )
            return (policy, snapshot, kinds)
        }
        processSentinel.apply(next.0, passKinds: next.2)
        filterPolicyHub.publish(next.1)
        filterStatusSink?.publish(next.1)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
