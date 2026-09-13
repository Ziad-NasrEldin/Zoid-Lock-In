import Foundation

public enum MarketplaceCoordinatorError: Error, Equatable, Sendable {
    case purchaseInFlight
}

extension MarketplaceCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .purchaseInFlight:
            return "A marketplace purchase is already in flight"
        }
    }
}

/// User-space purchase coordinator: atomic ledger debit, HMAC voucher, XPC redeem.
///
/// The privileged daemon never opens SQLite. This type lives with the engine in
/// user space and talks to the helper only through `AmenityPassRedeeming`.
public final class MarketplaceCoordinator: @unchecked Sendable {
    public let engine: ExchangeEngine
    public let catalog: AmenityCatalog
    public let issuer: AmenityVoucherIssuer
    public let queueLabel: String

    private let redeemer: (any AmenityPassRedeeming)?
    private let shield: (any MobileShieldPublishing)?
    private let clock: any MonotonicTimeProviding
    private let lock = NSLock()
    private var localTimers: [AmenityKind: (startedAt: TimeInterval, durationSeconds: TimeInterval)] = [:]
    private var lastError: String?
    private var inFlight = false

    public init(
        engine: ExchangeEngine,
        issuer: AmenityVoucherIssuer = AmenityVoucherIssuer(),
        redeemer: (any AmenityPassRedeeming)? = nil,
        clock: (any MonotonicTimeProviding)? = nil,
        shield: (any MobileShieldPublishing)? = nil
    ) {
        self.engine = engine
        self.catalog = engine.catalog
        self.issuer = issuer
        self.redeemer = redeemer
        self.clock = clock ?? MachContinuousTimeClock()
        self.shield = shield
        self.queueLabel = "zoidlockin.economy"
    }

    public var purchaseError: String? {
        withLock { lastError }
    }

    public var purchaseInFlight: Bool {
        withLock { inFlight }
    }

    public func snapshot(status: EnforcementStatus? = nil) throws -> MarketplaceSnapshot {
        let ticker = try engine.snapshot()
        return assemble(ticker: ticker, status: status)
    }

    public func assemble(
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        mobileShield: MobileShieldStatus? = nil
    ) -> MarketplaceSnapshot {
        let captured = withLock { () -> (String?, [AmenityKind: Int], Bool) in
            (lastError, localRemainingLocked(at: clock.nowSeconds()), inFlight)
        }
        let resolvedShield: MobileShieldStatus?
        if let mobileShield {
            resolvedShield = mobileShield
        } else if let shield {
            resolvedShield = shield.currentStatus
        } else {
            resolvedShield = nil
        }
        return MarketplaceSnapshot.assemble(
            ticker: ticker,
            catalog: catalog,
            status: status,
            localRemaining: captured.1,
            purchaseError: captured.0,
            purchaseInFlight: captured.2,
            mobileShield: resolvedShield
        )
    }

    @discardableResult
    public func purchase(_ kind: AmenityKind) async throws -> AmenityPurchase {
        try beginPurchase()
        defer { endPurchase() }
        do {
            if kind.passKind != nil, redeemer == nil {
                throw EnforcementControlError.amenityPassRequiresVoucher
            }
            let result = try engine.purchaseAmenity(kind, issuer: issuer)
            if let voucher = result.voucher {
                guard let redeemer else {
                    try engine.refundAmenity(result)
                    throw EnforcementControlError.amenityPassRequiresVoucher
                }
                do {
                    try await redeemer.redeemAmenityVoucher(voucher)
                } catch {
                    if Self.isReplayOfAlreadyGrantedPass(error) {
                        setPurchaseError(nil)
                        return result
                    }
                    try engine.refundAmenity(result)
                    throw error
                }
            }
            if kind == .rest, let duration = result.durationSeconds {
                recordRest(durationSeconds: TimeInterval(duration))
            }
            await publishShield(after: result)
            setPurchaseError(nil)
            return result
        } catch {
            setPurchaseError(Self.message(for: error))
            throw error
        }
    }

    public func localRemaining(at time: TimeInterval? = nil) -> [AmenityKind: Int] {
        withLock { localRemainingLocked(at: time ?? clock.nowSeconds()) }
    }

    public static func message(for error: Error) -> String {
        if let engine = error as? ExchangeEngineError, let description = engine.errorDescription {
            return description
        }
        if let control = error as? EnforcementControlError, let description = control.errorDescription {
            return description
        }
        if let voucher = error as? AmenityVoucherError, let description = voucher.errorDescription {
            return description
        }
        if let coordinator = error as? MarketplaceCoordinatorError, let description = coordinator.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func isReplayOfAlreadyGrantedPass(_ error: Error) -> Bool {
        if let control = error as? EnforcementControlError, control == .replayNonceRejected {
            return true
        }
        return false
    }

    private func publishShield(after purchase: AmenityPurchase) async {
        guard let shield else { return }
        let ticker = (try? engine.snapshot()) ?? .proof
        let event: MobileShieldEvent
        if let passKind = purchase.kind.passKind, let duration = purchase.durationSeconds {
            event = .passRedeemed(kind: passKind, durationSeconds: duration)
        } else {
            event = .focusTick
        }
        var status: EnforcementStatus?
        if let querying = redeemer as? any EnforcementStatusQuerying {
            status = try? await querying.queryStatus()
        }
        _ = await shield.publish(
            ticker: ticker,
            status: status,
            now: engine.wallTime(),
            event: event
        )
    }

    private func beginPurchase() throws {
        try withLock {
            if inFlight {
                throw MarketplaceCoordinatorError.purchaseInFlight
            }
            inFlight = true
        }
    }

    private func endPurchase() {
        withLock { inFlight = false }
    }

    private func recordRest(durationSeconds: TimeInterval) {
        withLock {
            localTimers[.rest] = (clock.nowSeconds(), durationSeconds)
        }
    }

    private func setPurchaseError(_ message: String?) {
        withLock { lastError = message }
    }

    private func localRemainingLocked(at time: TimeInterval) -> [AmenityKind: Int] {
        var remaining: [AmenityKind: Int] = [:]
        for (kind, timer) in localTimers {
            let left = max(0, Int((timer.startedAt + timer.durationSeconds - time).rounded(.towardZero)))
            if left > 0 {
                remaining[kind] = left
            }
        }
        return remaining
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
