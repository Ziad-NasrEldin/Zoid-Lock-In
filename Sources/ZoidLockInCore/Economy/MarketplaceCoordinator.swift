import Foundation

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
    private let clock: any MonotonicTimeProviding
    private let lock = NSLock()
    private var localTimers: [AmenityKind: (startedAt: TimeInterval, durationSeconds: TimeInterval)] = [:]
    private var lastError: String?

    public init(
        engine: ExchangeEngine,
        issuer: AmenityVoucherIssuer = AmenityVoucherIssuer(),
        redeemer: (any AmenityPassRedeeming)? = nil,
        clock: (any MonotonicTimeProviding)? = nil
    ) {
        self.engine = engine
        self.catalog = engine.catalog
        self.issuer = issuer
        self.redeemer = redeemer
        self.clock = clock ?? MachContinuousTimeClock()
        self.queueLabel = "zoidlockin.economy"
    }

    public var purchaseError: String? {
        withLock { lastError }
    }

    public func snapshot(status: EnforcementStatus? = nil) throws -> MarketplaceSnapshot {
        let ticker = try engine.snapshot()
        return assemble(ticker: ticker, status: status)
    }

    public func assemble(ticker: MenuBarTickerSnapshot, status: EnforcementStatus?) -> MarketplaceSnapshot {
        let captured = withLock { () -> (String?, [AmenityKind: Int]) in
            (lastError, localRemainingLocked(at: clock.nowSeconds()))
        }
        return MarketplaceSnapshot.assemble(
            ticker: ticker,
            catalog: catalog,
            status: status,
            localRemaining: captured.1,
            purchaseError: captured.0
        )
    }

    @discardableResult
    public func purchase(_ kind: AmenityKind) async throws -> AmenityPurchase {
        do {
            if kind.passKind != nil, redeemer == nil {
                throw EnforcementControlError.amenityPassRequiresVoucher
            }
            let result = try engine.purchaseAmenity(kind, issuer: issuer)
            if let voucher = result.voucher {
                guard let redeemer else {
                    throw EnforcementControlError.amenityPassRequiresVoucher
                }
                try await redeemer.redeemAmenityVoucher(voucher)
            }
            if kind == .rest, let duration = result.durationSeconds {
                recordRest(durationSeconds: TimeInterval(duration))
            }
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
        return error.localizedDescription
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
