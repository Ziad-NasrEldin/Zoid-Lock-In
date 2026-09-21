import CryptoKit
import Foundation

/// 48-hour configuration rate-limit. Remaining time uses monotonic accrual so
/// advancing System Settings cannot expire the lock. SQLite rows are HMAC-sealed.
public final class GovernanceLockCoordinator: @unchecked Sendable {
    public let store: any GovernanceStoring
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let timeTravel: TimeTravelGuard
    public let bootSessionUUID: String
    public private(set) var isCooldownBypassEnabled: Bool
    public let replicaSealStore: (any GovernanceSealPersisting)?
    public let gatekeeper: SecurityGatekeeper?

    public var onAmenityPricesChanged: (([AmenityKind: Double]) -> Void)?
    public var onBlocklistChanged: ((DomainFilterRules) -> Void)?

    private let keyProvider: any GovernanceKeyProviding
    private let defaultPinnedTimeZone: TimeZone
    private let lock = NSRecursiveLock()
    private weak var boundEngine: ExchangeEngine?
    private var cachedKey: SymmetricKey?

    public convenience init(
        store: any GovernanceStoring,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        bootSessionUUID: String = BootSession.currentUUID(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyProvider: any GovernanceKeyProviding = InMemoryGovernanceKeyProvider(),
        replicaSealStore: (any GovernanceSealPersisting)? = nil,
        pinnedTimeZone: TimeZone = .current,
        gatekeeper: SecurityGatekeeper? = nil
    ) {
        self.init(
            store: store,
            clock: clock,
            wallClock: wallClock,
            timeTravel: timeTravel,
            bootSessionUUID: bootSessionUUID,
            environment: environment,
            keyProvider: keyProvider,
            replicaSealStore: replicaSealStore,
            pinnedTimeZone: pinnedTimeZone,
            gatekeeper: gatekeeper,
            testConfiguration: nil
        )
    }

    init(
        store: any GovernanceStoring,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        bootSessionUUID: String = BootSession.currentUUID(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyProvider: any GovernanceKeyProviding = InMemoryGovernanceKeyProvider(),
        replicaSealStore: (any GovernanceSealPersisting)? = nil,
        pinnedTimeZone: TimeZone = .current,
        gatekeeper: SecurityGatekeeper? = nil,
        testConfiguration: GovernanceLockTestConfiguration?
    ) {
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.timeTravel = timeTravel
        self.bootSessionUUID = bootSessionUUID
        self.keyProvider = keyProvider
        self.replicaSealStore = replicaSealStore
        self.gatekeeper = gatekeeper
        self.defaultPinnedTimeZone = pinnedTimeZone
        let injectedBypass = testConfiguration?.bypassCooldown == true
        #if DEBUG
        self.isCooldownBypassEnabled = injectedBypass
            || GovernanceLockPolicy.isEnvironmentBypassEnabled(environment)
        #else
        self.isCooldownBypassEnabled = injectedBypass
        _ = environment
        #endif
        restoreTimeTravelOrigin()
        _ = ensurePinnedTimeZone()
    }

    public var pinnedTimeZone: TimeZone {
        withLock {
            if let identifier = (try? verifiedStateLocked())?.pinnedTimeZoneIdentifier
                ?? (try? store.loadGovernanceState())?.pinnedTimeZoneIdentifier,
               let timeZone = TimeZone(identifier: identifier) {
                return timeZone
            }
            return defaultPinnedTimeZone
        }
    }

    /// Loads stored amenity overrides into the live engine and publishes composed
    /// domain rules to any blocklist observer (filter / daemon).
    public func bind(engine: ExchangeEngine) {
        withLock {
            boundEngine = engine
            publishLiveSettingsLocked()
        }
    }

    public func publishLiveSettings() {
        withLock { publishLiveSettingsLocked() }
    }

    public func snapshot() -> GovernanceLockSnapshot {
        withLock {
            do {
                let remaining = try accrueLocked()
                let state = try verifiedStateLocked()
                let locked = (remaining > 0 && state.hasMutation && !isCooldownBypassEnabled)
                return GovernanceLockSnapshot(
                    isLocked: locked,
                    remainingSeconds: isCooldownBypassEnabled ? 0 : remaining,
                    isBypassEnabled: isCooldownBypassEnabled,
                    lastConfigurationMutationAt: state.lastConfigurationMutationAt,
                    isClockTampered: timeTravel.isTampered
                )
            } catch {
                return .failClosed(isClockTampered: timeTravel.isTampered)
            }
        }
    }

    public func remainingSeconds() throws -> TimeInterval {
        try withLock { try accrueLocked() }
    }

    /// Throws if configuration interfaces must stay read-only.
    public func ensureMutable() throws {
        try withLock {
            let remaining = try accrueLocked()
            if timeTravel.isTampered {
                throw GovernanceLockError.clockTampered(skewSeconds: timeTravel.lastObservedSkewSeconds)
            }
            if isCooldownBypassEnabled {
                return
            }
            if remaining > 0 {
                throw GovernanceLockError.cooldownActive(remainingSeconds: remaining)
            }
        }
    }

    /// Runs a configuration mutation and starts (or refreshes) the 48-hour lock.
    @discardableResult
    public func performMutation<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            try ensureMutableLocked()
            try requireSecurityUnlockedLocked()
            let result = try body()
            try recordMutationLocked()
            publishLiveSettingsLocked()
            gatekeeper?.noteConfigurationMutation()
            return result
        }
    }

    @discardableResult
    public func recordMutation() throws -> GovernanceState {
        try withLock {
            try ensureMutableLocked()
            try requireSecurityUnlockedLocked()
            let state = try recordMutationLocked()
            publishLiveSettingsLocked()
            gatekeeper?.noteConfigurationMutation()
            return state
        }
    }

    @discardableResult
    public func setAmenityPrice(_ kind: AmenityKind, cost: Double) throws -> Double {
        let normalized = CreditMath.normalize(cost)
        guard normalized >= 0, normalized <= 50 else {
            throw GovernanceLockError.invalidAmenityPrice
        }
        return try performMutation {
            try store.upsertAmenityPriceOverride(
                kind: kind,
                cost: normalized,
                updatedAt: wallClock.now()
            )
            return normalized
        }
    }

    @discardableResult
    public func addBlocklistSuffix(_ suffix: String) throws -> BlocklistRule {
        guard let verified = DomainFilterRules.verifiedHostname(suffix) else {
            throw GovernanceLockError.invalidBlocklistSuffix
        }
        let rule = BlocklistRule(suffix: verified, createdAt: wallClock.now())
        return try performMutation {
            try store.upsertBlocklistRule(rule)
            return rule
        }
    }

    public func removeBlocklistSuffix(_ suffix: String) throws {
        guard DomainFilterRules.verifiedHostname(suffix) != nil else {
            throw GovernanceLockError.invalidBlocklistSuffix
        }
        try performMutation {
            try store.deleteBlocklistRule(suffix: suffix)
        }
    }

    public func setCooldownBypassEnabled(_ enabled: Bool) {
        withLock {
            isCooldownBypassEnabled = enabled
            publishLiveSettingsLocked()
        }
    }

    public func resetLockForAdmin() throws {
        try withLock {
            timeTravel.clearTamper()
            var state = (try? verifiedStateLocked()) ?? .empty
            state.lastConfigurationMutationAt = nil
            state.lastConfigurationMutationMonotonic = nil
            state.mutationBootSessionUUID = nil
            state.accruedMonotonicElapsed = 0
            state.lastObservedWall = wallClock.now()
            state.lastObservedMonotonic = clock.nowSeconds()
            state.lastObservedBootSessionUUID = bootSessionUUID
            try persistStateLocked(state)
            publishLiveSettingsLocked()
        }
    }

    public func amenityPriceOverrides() throws -> [AmenityKind: Double] {
        try store.loadAmenityPriceOverrides()
    }

    public func blocklistRules() throws -> [BlocklistRule] {
        try store.loadBlocklistRules()
    }

    public func composedDomainRules(defaults: DomainFilterRules = DomainFilterRules()) throws -> DomainFilterRules {
        let extras = try blocklistRules().map(\.suffix)
        return defaults.withAdditionalBlacklist(extras)
    }

    public func composedEnforcementPolicy() throws -> EnforcementPolicy {
        var policy = EnforcementPolicy.lockedDown
        policy.domainRules = try composedDomainRules()
        return policy
    }

    @discardableResult
    public func ensurePinnedTimeZone() -> TimeZone {
        withLock {
            do {
                var state = try verifiedStateLocked()
                if let identifier = state.pinnedTimeZoneIdentifier,
                   let timeZone = TimeZone(identifier: identifier) {
                    return timeZone
                }
                state.pinnedTimeZoneIdentifier = defaultPinnedTimeZone.identifier
                try persistStateLocked(state)
                return defaultPinnedTimeZone
            } catch {
                return defaultPinnedTimeZone
            }
        }
    }

    private func restoreTimeTravelOrigin() {
        guard let state = try? store.loadGovernanceState(),
              let wall = state.lastObservedWall,
              let mono = state.lastObservedMonotonic,
              BootSession.isSameBoot(state.lastObservedBootSessionUUID, bootSessionUUID)
        else {
            return
        }
        timeTravel.restoreOriginIfNeeded(wall: wall, monotonic: mono)
    }

    private func ensureMutableLocked() throws {
        let remaining = try accrueLocked(persist: true)
        if timeTravel.isTampered {
            throw GovernanceLockError.clockTampered(skewSeconds: timeTravel.lastObservedSkewSeconds)
        }
        if isCooldownBypassEnabled {
            return
        }
        if remaining > 0 {
            throw GovernanceLockError.cooldownActive(remainingSeconds: remaining)
        }
    }

    private func requireSecurityUnlockedLocked() throws {
        guard let gatekeeper, gatekeeper.isEnrolled else { return }
        try gatekeeper.requireUnlocked()
    }

    @discardableResult
    private func accrueLocked(persist: Bool = false) throws -> TimeInterval {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        timeTravel.observe(wall: nowWall, monotonic: nowMono)

        var state = try verifiedStateLocked()
        var delta: TimeInterval = 0
        if let lastMono = state.lastObservedMonotonic,
           BootSession.isSameBoot(state.lastObservedBootSessionUUID, bootSessionUUID) {
            let elapsed = nowMono - lastMono
            if elapsed > 0 {
                delta = elapsed
            }
        }

        let totalAccrued = state.accruedMonotonicElapsed + delta
        guard state.hasMutation else {
            if state.pinnedTimeZoneIdentifier == nil {
                state.pinnedTimeZoneIdentifier = defaultPinnedTimeZone.identifier
                try persistStateLocked(state)
            }
            return 0
        }

        var remaining = max(0, GovernanceLockPolicy.cooldownSeconds - totalAccrued)
        if timeTravel.isTampered {
            remaining = max(1, remaining)
        }

        let shouldPersist = persist || (remaining == 0 && state.accruedMonotonicElapsed < GovernanceLockPolicy.cooldownSeconds) || delta >= 60
        if shouldPersist {
            state.accruedMonotonicElapsed = totalAccrued
            state.lastObservedWall = nowWall
            state.lastObservedMonotonic = nowMono
            state.lastObservedBootSessionUUID = bootSessionUUID
            if state.pinnedTimeZoneIdentifier == nil {
                state.pinnedTimeZoneIdentifier = defaultPinnedTimeZone.identifier
            }
            try persistStateLocked(state)
        }

        return remaining
    }

    @discardableResult
    private func recordMutationLocked() throws -> GovernanceState {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        timeTravel.observe(wall: nowWall, monotonic: nowMono)
        var state = (try? verifiedStateLocked()) ?? .empty
        state.lastConfigurationMutationAt = nowWall
        state.lastConfigurationMutationMonotonic = nowMono
        state.mutationBootSessionUUID = bootSessionUUID
        state.lastObservedWall = nowWall
        state.lastObservedMonotonic = nowMono
        state.lastObservedBootSessionUUID = bootSessionUUID
        state.accruedMonotonicElapsed = 0
        if state.pinnedTimeZoneIdentifier == nil {
            state.pinnedTimeZoneIdentifier = defaultPinnedTimeZone.identifier
        }
        try persistStateLocked(state)
        return state
    }

    private func persistStateLocked(_ state: GovernanceState) throws {
        var next = state
        next.sequence = max(state.sequence, (try? store.loadGovernanceState().sequence) ?? 0) + 1
        let key = try sealKeyLocked()
        let envelope = try GovernanceSeal.seal(GovernanceSealPayload(next), key: key)
        try store.saveGovernanceState(next)
        try store.saveGovernanceEnvelope(envelope)
        try replicaSealStore?.saveEnvelope(envelope)
    }

    private func verifiedStateLocked() throws -> GovernanceState {
        let sqlite = try store.loadGovernanceState()
        let envelope = try store.loadGovernanceEnvelope()
        let replica = try replicaSealStore?.loadEnvelope()
        let key = try sealKeyLocked()
        return try GovernanceIntegrity.verify(
            sqlite: sqlite,
            envelope: envelope,
            replica: replica,
            key: key
        )
    }

    private func sealKeyLocked() throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }
        let key = try keyProvider.loadOrCreate()
        cachedKey = key
        return key
    }

    private func publishLiveSettingsLocked() {
        let overrides = (try? store.loadAmenityPriceOverrides()) ?? [:]
        boundEngine?.applyAmenityPriceOverrides(overrides)
        onAmenityPricesChanged?(overrides)
        if let rules = try? composedDomainRules() {
            onBlocklistChanged?(rules)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
