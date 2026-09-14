import Foundation

/// 48-hour configuration rate-limit. Remaining time uses monotonic accrual so
/// advancing System Settings cannot expire the lock.
public final class GovernanceLockCoordinator: @unchecked Sendable {
    public let store: any GovernanceStoring
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let timeTravel: TimeTravelGuard
    public let bootSessionUUID: String
    public let isCooldownBypassEnabled: Bool

    private let lock = NSRecursiveLock()

    public init(
        store: any GovernanceStoring,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        bootSessionUUID: String = BootSession.currentUUID(),
        isCooldownBypassEnabled: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.timeTravel = timeTravel
        self.bootSessionUUID = bootSessionUUID
        self.isCooldownBypassEnabled = isCooldownBypassEnabled
            || GovernanceLockPolicy.isEnvironmentBypassEnabled(environment)
        restoreTimeTravelOrigin()
    }

    public func snapshot() -> GovernanceLockSnapshot {
        withLock {
            let remaining = (try? accrueLocked()) ?? GovernanceLockPolicy.cooldownSeconds
            let state = (try? store.loadGovernanceState()) ?? .empty
            let locked = remaining > 0 && state.hasMutation && !isCooldownBypassEnabled
            return GovernanceLockSnapshot(
                isLocked: locked,
                remainingSeconds: isCooldownBypassEnabled ? 0 : remaining,
                isBypassEnabled: isCooldownBypassEnabled,
                lastConfigurationMutationAt: state.lastConfigurationMutationAt,
                isClockTampered: timeTravel.isTampered
            )
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
            let result = try body()
            try recordMutationLocked()
            return result
        }
    }

    @discardableResult
    public func recordMutation() throws -> GovernanceState {
        try withLock {
            try ensureMutableLocked()
            return try recordMutationLocked()
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

    public func amenityPriceOverrides() throws -> [AmenityKind: Double] {
        try store.loadAmenityPriceOverrides()
    }

    public func blocklistRules() throws -> [BlocklistRule] {
        try store.loadBlocklistRules()
    }

    public func composedDomainRules(defaults: DomainFilterRules = DomainFilterRules()) throws -> DomainFilterRules {
        let extras = try blocklistRules().map(\.suffix)
        return DomainFilterRules(
            blacklistedSuffixes: defaults.blacklistedSuffixes + extras,
            whitelistedSuffixes: defaults.whitelistedSuffixes
        )
    }

    private func restoreTimeTravelOrigin() {
        guard let state = try? store.loadGovernanceState(),
              let wall = state.lastObservedWall,
              let mono = state.lastObservedMonotonic,
              state.lastObservedBootSessionUUID == bootSessionUUID
        else {
            return
        }
        timeTravel.restoreOriginIfNeeded(wall: wall, monotonic: mono)
    }

    private func ensureMutableLocked() throws {
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

    @discardableResult
    private func accrueLocked() throws -> TimeInterval {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        timeTravel.observe(wall: nowWall, monotonic: nowMono)

        var state = try store.loadGovernanceState()
        if let lastMono = state.lastObservedMonotonic,
           state.lastObservedBootSessionUUID == bootSessionUUID {
            let delta = nowMono - lastMono
            if delta > 0 {
                state.accruedMonotonicElapsed += delta
            }
        }

        state.lastObservedWall = nowWall
        state.lastObservedMonotonic = nowMono
        state.lastObservedBootSessionUUID = bootSessionUUID
        try store.saveGovernanceState(state)

        guard state.hasMutation else {
            return 0
        }

        var remaining = max(0, GovernanceLockPolicy.cooldownSeconds - state.accruedMonotonicElapsed)
        if timeTravel.isTampered {
            remaining = max(1, remaining)
        }
        return remaining
    }

    @discardableResult
    private func recordMutationLocked() throws -> GovernanceState {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        timeTravel.observe(wall: nowWall, monotonic: nowMono)
        let state = GovernanceState(
            lastConfigurationMutationAt: nowWall,
            lastConfigurationMutationMonotonic: nowMono,
            mutationBootSessionUUID: bootSessionUUID,
            lastObservedWall: nowWall,
            lastObservedMonotonic: nowMono,
            lastObservedBootSessionUUID: bootSessionUUID,
            accruedMonotonicElapsed: 0
        )
        try store.saveGovernanceState(state)
        return state
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
