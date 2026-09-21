import Foundation

public struct MobileShieldPublication: Sendable, Equatable {
    public var state: MobileShieldState
    public var status: MobileShieldStatus
    public var pushOutcome: PushRelayOutcome
    public var command: PushRelayCommand?

    public init(
        state: MobileShieldState,
        status: MobileShieldStatus,
        pushOutcome: PushRelayOutcome,
        command: PushRelayCommand?
    ) {
        self.state = state
        self.status = status
        self.pushOutcome = pushOutcome
        self.command = command
    }
}

public protocol MobileShieldPublishing: Sendable {
    var currentStatus: MobileShieldStatus { get }
    var currentState: MobileShieldState { get }

    func publish(
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        now: Date,
        event: MobileShieldEvent
    ) async -> MobileShieldPublication
}

/// Isolated `state.json` writer + authenticated Cloudflare silent-push dispatcher.
/// Failures never throw: local lockdown continues if iCloud or the relay is down.
public final class MobileShieldCoordinator: MobileShieldPublishing, @unchecked Sendable {
    public let store: EncryptedStateStore
    public let relay: PushRelayClient

    private let lock = NSLock()
    private var lastState: MobileShieldState
    private var lastStatus: MobileShieldStatus
    private var publishTail: Task<MobileShieldPublication, Never>?

    public init(
        store: EncryptedStateStore,
        relay: PushRelayClient = PushRelayClient()
    ) {
        self.store = store
        self.relay = relay
        let loaded: MobileShieldState
        do {
            loaded = try store.load() ?? .empty
        } catch {
            loaded = .empty
        }
        self.lastState = loaded
        self.lastStatus = MobileShieldStatus.from(
            state: loaded,
            link: Self.link(for: relay.configuration),
            relayConfigured: relay.configuration.isConfigured
        )
    }

    public var currentStatus: MobileShieldStatus {
        withLock { lastStatus }
    }

    public var currentState: MobileShieldState {
        withLock { lastState }
    }

    public func publish(
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        now: Date = Date(),
        event: MobileShieldEvent
    ) async -> MobileShieldPublication {
        let task: Task<MobileShieldPublication, Never> = withLock {
            let predecessor = publishTail
            let next = Task {
                _ = await predecessor?.value
                return await self.publishExclusive(
                    ticker: ticker,
                    status: status,
                    now: now,
                    event: event
                )
            }
            publishTail = next
            return next
        }
        return await task.value
    }

    public func sync(
        engine: ExchangeEngine,
        status: EnforcementStatus? = nil,
        now: Date = Date(),
        event: MobileShieldEvent
    ) async -> MobileShieldPublication {
        let ticker = (try? engine.snapshot()) ?? .proof
        return await publish(ticker: ticker, status: status, now: now, event: event)
    }

    public static func command(
        for event: MobileShieldEvent,
        state: MobileShieldState
    ) -> PushRelayCommand {
        if state.hasEmergencyPass {
            return .releaseLockdown
        }
        switch event {
        case .passExpired:
            if !state.hasMobilePass {
                return .engageLockdown
            }
        case .passRedeemed(let kind, _) where kind.isMobileShieldPass:
            return .passUnlocked
        case .passRedeemed, .focusCompleted, .focusStarted, .focusTick:
            break
        }
        if state.hasMobilePass {
            return .passUnlocked
        }
        return .engageLockdown
    }

    public static func link(for configuration: PushRelayConfiguration) -> MobileShieldLink {
        if configuration.isConfigured {
            return .synced
        }
        return .localOnly
    }

    private func publishExclusive(
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        now: Date,
        event: MobileShieldEvent
    ) async -> MobileShieldPublication {
        let previous = withLock { lastState }
        let relayConfigured = relay.configuration.isConfigured
        let link = Self.link(for: relay.configuration)

        if ticker.isClockTampered {
            let ui = MobileShieldStatus.from(
                state: previous,
                link: link,
                relayConfigured: relayConfigured
            )
            let publication = MobileShieldPublication(
                state: previous,
                status: ui,
                pushOutcome: .skipped,
                command: nil
            )
            withLock { lastStatus = ui }
            return publication
        }

        let inferred = inferEvent(
            previous: previous,
            ticker: ticker,
            status: status,
            now: now,
            hinted: event
        )
        let drafted = makeState(
            previous: previous,
            ticker: ticker,
            status: status,
            now: now,
            event: inferred
        )
        let advanced = drafted.advancingSequence(to: now)
        let persisted = persistSilently(advanced, fallback: previous, now: now)
        let command = command(for: inferred, state: persisted)
        let expiredWithoutPass = inferred.isPassExpired && !persisted.hasMobilePass
        let shouldPush = shouldDispatchPush(event: inferred) || expiredWithoutPass
        let outcome: PushRelayOutcome
        if shouldPush {
            let payload = PushRelayPayload.make(
                command: command,
                state: persisted,
                targetPassKind: targetKind(for: inferred, command: command, state: persisted),
                durationSeconds: duration(for: inferred, command: command, state: persisted),
                now: now
            )
            outcome = await relay.dispatch(payload, now: now)
        } else {
            outcome = .skipped
        }

        let ui = MobileShieldStatus.from(
            state: persisted,
            link: link,
            relayConfigured: relayConfigured
        )
        let publication = MobileShieldPublication(
            state: persisted,
            status: ui,
            pushOutcome: outcome,
            command: shouldPush ? command : nil
        )
        withLock {
            lastState = persisted
            lastStatus = ui
        }
        return publication
    }

    private func command(for event: MobileShieldEvent, state: MobileShieldState) -> PushRelayCommand {
        Self.command(for: event, state: state)
    }

    private func persistSilently(
        _ advanced: MobileShieldState,
        fallback: MobileShieldState,
        now: Date
    ) -> MobileShieldState {
        do {
            return try store.persist(advanced, now: now)
        } catch {
            return fallback
        }
    }

    private func makeState(
        previous: MobileShieldState,
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        now: Date,
        event: MobileShieldEvent
    ) -> MobileShieldState {
        let sessionActive = ticker.focusState == .active || ticker.focusState == .pausedGrace
        var passes = passes(from: status, now: now)
        for record in previous.activePasses {
            let remaining = record.remaining(at: now)
            if remaining > 0, !passes.contains(where: { $0.kind == record.kind }) {
                passes.append(
                    MobilePassRecord(
                        kind: record.kind,
                        expiresAtUtc: record.expiresAtUtc,
                        remainingDurationSeconds: remaining,
                        localRelockDurationSeconds: remaining
                    )
                )
            }
        }
        switch event {
        case .passRedeemed(let kind, let duration) where duration > 0:
            passes.removeAll { $0.kind == kind }
            passes.append(
                MobilePassRecord(
                    kind: kind,
                    expiresAtUtc: now.addingTimeInterval(TimeInterval(duration)),
                    remainingDurationSeconds: duration,
                    localRelockDurationSeconds: duration
                )
            )
        case .passExpired(let kind):
            passes.removeAll { $0.kind == kind }
        default:
            break
        }
        return MobileShieldState(
            sessionActive: sessionActive,
            activePasses: passes,
            sequenceNumber: previous.sequenceNumber,
            timestamp: previous.timestamp,
            streakDays: ticker.currentStreak,
            balanceCredits: ticker.spendableBalance,
            now: now
        )
    }

    private func passes(from status: EnforcementStatus?, now: Date) -> [MobilePassRecord] {
        (status?.activePasses ?? []).compactMap { pass in
            guard pass.remainingSeconds > 0 else { return nil }
            return MobilePassRecord(
                kind: pass.kind,
                expiresAtUtc: now.addingTimeInterval(TimeInterval(pass.remainingSeconds)),
                remainingDurationSeconds: pass.remainingSeconds,
                localRelockDurationSeconds: pass.remainingSeconds
            )
        }
    }

    private func inferEvent(
        previous: MobileShieldState,
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        now: Date,
        hinted: MobileShieldEvent
    ) -> MobileShieldEvent {
        switch hinted {
        case .focusStarted, .focusCompleted, .passRedeemed, .passExpired:
            return hinted
        case .focusTick:
            break
        }

        let sessionActive = ticker.focusState == .active || ticker.focusState == .pausedGrace
        if !previous.sessionActive && sessionActive {
            return .focusStarted
        }
        if previous.sessionActive && !sessionActive {
            return .focusCompleted
        }

        let nextEmergency = status?.activePasses.contains {
            $0.kind == .emergency && $0.remainingSeconds > 0
        } ?? false
        if !previous.hasEmergencyPass && nextEmergency {
            let duration = status?.activePasses.first { $0.kind == .emergency }?.remainingSeconds ?? 0
            return .passRedeemed(kind: .emergency, durationSeconds: duration)
        }
        if previous.hasEmergencyPass && !nextEmergency {
            return .passExpired(kind: .emergency)
        }

        let previousKinds = Set(previous.mobilePassKinds)
        let nextKinds: Set<PassKind>
        if let status {
            nextKinds = Set(status.activePasses.compactMap { pass -> PassKind? in
                guard pass.remainingSeconds > 0, pass.kind.isMobileShieldPass else { return nil }
                return pass.kind
            })
        } else {
            nextKinds = Set(
                previous.activePasses
                    .filter { $0.kind.isMobileShieldPass && $0.isLive(at: now) }
                    .map(\.kind)
            )
        }
        if let added = nextKinds.subtracting(previousKinds).sorted(by: <).first {
            let duration = status?.activePasses.first { $0.kind == added }?.remainingSeconds ?? 0
            return .passRedeemed(kind: added, durationSeconds: duration)
        }
        if let expired = previousKinds.subtracting(nextKinds).sorted(by: <).first,
           let record = previous.activePasses.first(where: { $0.kind == expired }),
           !record.isLive(at: now) {
            return .passExpired(kind: expired)
        }
        if let wallClockExpired = previous.activePasses.first(where: {
            $0.kind.isMobileShieldPass && !$0.isLive(at: now)
        }) {
            return .passExpired(kind: wallClockExpired.kind)
        }
        return .focusTick
    }

    private func shouldDispatchPush(event: MobileShieldEvent) -> Bool {
        switch event {
        case .focusTick:
            return false
        case .focusStarted, .focusCompleted, .passRedeemed, .passExpired:
            return true
        }
    }

    private func targetKind(
        for event: MobileShieldEvent,
        command: PushRelayCommand,
        state: MobileShieldState
    ) -> PassKind? {
        switch event {
        case .passRedeemed(let kind, _):
            return kind
        case .passExpired(let kind):
            if command == .passUnlocked {
                return state.primaryMobilePass?.kind
            }
            return kind
        case .focusStarted, .focusCompleted, .focusTick:
            if command == .passUnlocked {
                return state.primaryMobilePass?.kind
            }
            return nil
        }
    }

    private func duration(
        for event: MobileShieldEvent,
        command: PushRelayCommand,
        state: MobileShieldState
    ) -> Int? {
        switch event {
        case .passRedeemed(_, let duration):
            return duration
        case .passExpired, .focusStarted, .focusCompleted, .focusTick:
            if command == .passUnlocked {
                return state.primaryMobilePass?.remainingDurationSeconds
            }
            return 0
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension MobileShieldEvent {
    var isPassExpired: Bool {
        if case .passExpired = self {
            return true
        }
        return false
    }
}
