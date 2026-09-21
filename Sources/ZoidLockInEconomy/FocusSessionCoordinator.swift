import Foundation
import OSLog
import ZoidLockInCore

/// Coordinates live tracking signals from ZoidZeroLiveTracker with the ExchangeEngine,
/// automatically driving startFocus, grace pauses, and session completions.
public final class FocusSessionCoordinator: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.mavoid.zoidlockin",
        category: "FocusSessionCoordinator"
    )

    public let engine: ExchangeEngine
    public let tracker: ZoidZeroLiveTracker
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isCoordinationActive = false
    private var lastInterruptionStart: Date?
    public var onSnapshotUpdated: (@Sendable (MenuBarTickerSnapshot) -> Void)?

    public init(
        engine: ExchangeEngine,
        tracker: ZoidZeroLiveTracker = .shared,
        queue: DispatchQueue = DispatchQueue(label: "zoidlockin.focus-coordinator", qos: .userInitiated)
    ) {
        self.engine = engine
        self.tracker = tracker
        self.queue = queue
    }

    @MainActor
    public func start() {
        lock.lock()
        guard !isCoordinationActive else {
            lock.unlock()
            return
        }
        isCoordinationActive = true
        lock.unlock()

        tracker.onProductiveStateChanged = { [weak self] isProductiveAndActive, app in
            self?.handleStateChanged(isProductiveAndActive: isProductiveAndActive, app: app)
        }
        tracker.start()

        // Evaluate current frontmost status on launch
        let initialIsActive = tracker.isTrackingProductive
        let initialApp = tracker.currentFrontmost
        handleStateChanged(isProductiveAndActive: initialIsActive, app: initialApp)
    }

    public func stop() {
        lock.lock()
        guard isCoordinationActive else {
            lock.unlock()
            return
        }
        isCoordinationActive = false
        lock.unlock()
        tracker.stop()
    }

    public func handleStateChanged(isProductiveAndActive: Bool, app: TrackedAppIdentity?) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if isProductiveAndActive {
                    self.lock.lock()
                    self.lastInterruptionStart = nil
                    self.lock.unlock()

                    let currentSnapshot = try self.engine.snapshot()
                    if currentSnapshot.focusState == nil || currentSnapshot.focusState == .completed || currentSnapshot.focusState == .abandoned {
                        Self.logger.info("Automatically starting focus block for productive application")
                        _ = try self.engine.startFocus()
                    }
                } else {
                    self.lock.lock()
                    if self.lastInterruptionStart == nil {
                        self.lastInterruptionStart = Date()
                    }
                    self.lock.unlock()
                }

                let next = try self.engine.tick()
                self.onSnapshotUpdated?(next)
            } catch {
                Self.logger.error("Focus coordination tick failed")
            }
        }
    }
}
