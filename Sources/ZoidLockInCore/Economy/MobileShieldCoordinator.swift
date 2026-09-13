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

/// iCloud `state.json` writer + Cloudflare silent-push dispatcher.
/// Failures never throw: local lockdown continues if iCloud or the relay is down.
public final class MobileShieldCoordinator: MobileShieldPublishing, @unchecked Sendable {
    public let store: EncryptedStateStore
    public let relay: PushRelayClient

    private let lock = NSLock()
    private var lastState: MobileShieldState
    private var lastStatus: MobileShieldStatus

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
            link: MobileShieldStatus.inferredLink(
                sessionActive: loaded.sessionActive,
                passActive: loaded.hasMobilePass
            )
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
        let previous = withLock { lastState }
        let inferred = inferEvent(
            previous: previous,
            ticker: ticker,
            status: status,
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
        let persisted = persistSilently(advanced)
        let command = command(for: inferred, state: persisted)
        let shouldPush = shouldDispatchPush(event: inferred)
        let outcome: PushRelayOutcome
        if shouldPush {
            let payload = PushRelayPayload.make(
                command: command,
                state: persisted,
                targetPassKind: targetKind(for: inferred, command: command, state: persisted),
                durationSeconds: duration(for: inferred, command: command, state: persisted)
            )
            outcome = await relay.dispatch(payload)
        } else {
            outcome = .skipped
        }

        let ui = MobileShieldStatus.from(
            state: persisted,
            link: MobileShieldStatus.inferredLink(
                sessionActive: persisted.sessionActive,
                passActive: persisted.hasMobilePass
            )
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
        case .passRedeemed(let kind, _) where kind.isMobileShieldPass:
            return .passUnlocked
        case .passRedeemed:
            break
        case .passExpired, .focusCompleted, .focusStarted, .focusTick:
            break
        }
        if state.hasMobilePass {
            return .passUnlocked
        }
        return .engageLockdown
    }

    private func command(for event: MobileShieldEvent, state: MobileShieldState) -> PushRelayCommand {
        Self.command(for: event, state: state)
    }

    private func persistSilently(_ advanced: MobileShieldState) -> MobileShieldState {
        do {
            return try store.persist(advanced)
        } catch {
            return advanced
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
        if status == nil {
            for record in previous.activePasses {
                let remaining = max(
                    0,
                    Int(record.expiresAtUtc.timeIntervalSince(now).rounded(.towardZero))
                )
                if remaining > 0, !passes.contains(where: { $0.kind == record.kind }) {
                    passes.append(
                        MobilePassRecord(
                            kind: record.kind,
                            expiresAtUtc: record.expiresAtUtc,
                            remainingDurationSeconds: remaining
                        )
                    )
                }
            }
        }
        switch event {
        case .passRedeemed(let kind, let duration) where duration > 0:
            passes.removeAll { $0.kind == kind }
            passes.append(
                MobilePassRecord(
                    kind: kind,
                    expiresAtUtc: now.addingTimeInterval(TimeInterval(duration)),
                    remainingDurationSeconds: duration
                )
            )
        default:
            break
        }
        return MobileShieldState(
            sessionActive: sessionActive,
            activePasses: passes,
            sequenceNumber: previous.sequenceNumber,
            timestamp: previous.timestamp,
            streakDays: ticker.currentStreak,
            balanceCredits: ticker.spendableBalance
        )
    }

    private func passes(from status: EnforcementStatus?, now: Date) -> [MobilePassRecord] {
        (status?.activePasses ?? []).compactMap { pass in
            guard pass.remainingSeconds > 0 else { return nil }
            return MobilePassRecord(
                kind: pass.kind,
                expiresAtUtc: now.addingTimeInterval(TimeInterval(pass.remainingSeconds)),
                remainingDurationSeconds: pass.remainingSeconds
            )
        }
    }

    private func inferEvent(
        previous: MobileShieldState,
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
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
        let nextKinds = Set((status?.activePasses ?? []).compactMap { pass -> PassKind? in
            guard pass.remainingSeconds > 0, pass.kind.isMobileShieldPass else { return nil }
            return pass.kind
        })
        if let added = nextKinds.subtracting(previousKinds).sorted(by: <).first {
            let duration = status?.activePasses.first { $0.kind == added }?.remainingSeconds ?? 0
            return .passRedeemed(kind: added, durationSeconds: duration)
        }
        if let expired = previousKinds.subtracting(nextKinds).sorted(by: <).first {
            return .passExpired(kind: expired)
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
            return nil
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
