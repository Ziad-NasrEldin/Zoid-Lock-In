import AppKit
import CoreGraphics
import Foundation
import OSLog
import ZoidLockInCore

/// Represents an identified application active in macOS.
public struct TrackedAppIdentity: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String
    public let displayName: String
    public let isProductive: Bool
    public let domain: String?
    public let category: ZoidZeroActivityCategory

    public init(
        bundleIdentifier: String,
        displayName: String,
        isProductive: Bool,
        domain: String? = nil,
        category: ZoidZeroActivityCategory = .uncategorized
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isProductive = isProductive
        self.domain = domain
        self.category = category
    }
}

/// Reason why tracking is currently paused or in grace.
public enum TrackingPauseReason: String, Sendable, Equatable {
    case idle
    case sleep
    case locked
    case nonProductiveApp
}

/// Zoid 0 live application and anti-idle activity tracker.
///
/// Productive focus follows Zoid 0's categorized catalog: work apps and work
/// websites mint credits. Browsers only count when the active tab is work.
/// User recategorizations in Zoid 0's store.json are reloaded live.
public final class ZoidZeroLiveTracker: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.mavoid.zoidlockin",
        category: "ZoidZeroLiveTracker"
    )

    public static let shared = ZoidZeroLiveTracker()

    /// Compatibility surface: work-app prefixes derived from the Zoid 0 catalog.
    public static var defaultProductiveBundlePrefixes: Set<String> {
        var prefixes = ZoidZeroActivityCatalog.lockInWorkBundlePrefixes
        for (subject, category) in ZoidZeroActivityCatalog.defaultAssignments {
            guard category.isProductive else { continue }
            if case .application(let bundle) = subject {
                prefixes.insert(bundle)
            }
        }
        return prefixes
    }

    private let lock = NSLock()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var idleCheckTimer: DispatchSourceTimer?
    private var isStarted = false
    private var currentApp: TrackedAppIdentity?
    private var activePauseReasons: Set<TrackingPauseReason> = []
    private let idleThreshold: TimeInterval
    private let catalog: ZoidZeroActivityCatalog
    private let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    /// Callback invoked when the productive state changes.
    /// isProductiveAndActive is true when frontmost is a productive app AND user is not idle/locked/sleeping.
    public var onProductiveStateChanged: (@Sendable (_ isProductiveAndActive: Bool, _ app: TrackedAppIdentity?) -> Void)?

    public init(
        idleThreshold: TimeInterval = 90,
        catalog: ZoidZeroActivityCatalog = .shared
    ) {
        self.idleThreshold = idleThreshold
        self.catalog = catalog
    }

    public var currentFrontmost: TrackedAppIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return currentApp
    }

    public var isTrackingProductive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = currentApp else { return false }
        return current.isProductive && activePauseReasons.isEmpty
    }

    @MainActor
    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        registerWorkspaceObservers()
        registerSessionObservers()
        startIdleMonitor()

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            handleApplicationActivation(frontmost)
        }
    }

    public func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        idleCheckTimer?.cancel()
        idleCheckTimer = nil
        let ws = workspaceObservers
        let dist = distributedObservers
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        activePauseReasons.removeAll()
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        ws.forEach(center.removeObserver)
        let distCenter = DistributedNotificationCenter.default()
        dist.forEach(distCenter.removeObserver)
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let appObs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.handleApplicationActivation(app)
        }

        let sleepObs = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pause(reason: .sleep)
        }

        let wakeObs = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resume(reason: .sleep)
        }

        lock.lock()
        workspaceObservers.append(contentsOf: [appObs, sleepObs, wakeObs])
        lock.unlock()
    }

    private func registerSessionObservers() {
        let distCenter = DistributedNotificationCenter.default()

        let lockObs = distCenter.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pause(reason: .locked)
        }

        let unlockObs = distCenter.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resume(reason: .locked)
        }

        lock.lock()
        distributedObservers.append(contentsOf: [lockObs, unlockObs])
        lock.unlock()
    }

    private func startIdleMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.checkIdleDuration()
            self?.refreshFrontmostClassification()
        }
        lock.lock()
        idleCheckTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func checkIdleDuration() {
        let idle = currentIdleSeconds()
        if idle >= idleThreshold {
            pause(reason: .idle)
        } else {
            resume(reason: .idle)
        }
    }

    public func currentIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
    }

    private func refreshFrontmostClassification() {
        catalog.reloadIfNeeded()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        handleApplicationActivation(app)
    }

    private func handleApplicationActivation(_ app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? "Unknown"
        let domain = Self.frontmostBrowserDomain(bundleIdentifier: bundleId)
        let category = catalog.isBrowser(bundleId)
            ? catalog.category(for: .website(domain: domain ?? ""))
            : catalog.category(for: .application(bundleIdentifier: bundleId))
        let isProductive = catalog.isProductive(bundleIdentifier: bundleId, domain: domain)
        let identity = TrackedAppIdentity(
            bundleIdentifier: bundleId,
            displayName: name,
            isProductive: isProductive,
            domain: domain,
            category: category
        )

        lock.lock()
        let previous = currentApp
        currentApp = identity
        if !isProductive {
            activePauseReasons.insert(.nonProductiveApp)
        } else {
            activePauseReasons.remove(.nonProductiveApp)
        }
        let productiveAndActive = isProductive && activePauseReasons.isEmpty
        let changed = previous != identity
        let callback = onProductiveStateChanged
        lock.unlock()

        if changed {
            callback?(productiveAndActive, identity)
        }
    }

    private func pause(reason: TrackingPauseReason) {
        lock.lock()
        let wasActive = (currentApp?.isProductive == true) && activePauseReasons.isEmpty
        activePauseReasons.insert(reason)
        let current = currentApp
        let callback = onProductiveStateChanged
        lock.unlock()

        if wasActive {
            callback?(false, current)
        }
    }

    private func resume(reason: TrackingPauseReason) {
        lock.lock()
        activePauseReasons.remove(reason)
        let isNowActive = (currentApp?.isProductive == true) && activePauseReasons.isEmpty
        let current = currentApp
        let callback = onProductiveStateChanged
        lock.unlock()

        if isNowActive {
            callback?(true, current)
        }
    }

    public static func isProductive(bundleIdentifier: String, domain: String? = nil) -> Bool {
        ZoidZeroActivityCatalog.shared.isProductive(
            bundleIdentifier: bundleIdentifier,
            domain: domain
        )
    }

    public static func frontmostBrowserDomain(bundleIdentifier: String) -> String? {
        let source: String
        if bundleIdentifier.hasPrefix("com.apple.Safari") {
            source = "tell application id \"com.apple.Safari\" to get URL of current tab of front window"
        } else if bundleIdentifier.hasPrefix("com.google.Chrome") {
            source = "tell application id \"com.google.Chrome\" to get URL of active tab of front window"
        } else if bundleIdentifier.hasPrefix("company.thebrowser.Browser") {
            source = "tell application id \"company.thebrowser.Browser\" to get URL of active tab of front window"
        } else {
            return nil
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        guard error == nil, let url = result?.stringValue else {
            return nil
        }
        return ZoidZeroActivityCatalog.normalizedDomain(from: url)
    }
}
