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

    public init(bundleIdentifier: String, displayName: String, isProductive: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isProductive = isProductive
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
/// Ported directly from Zoid 0's ApplicationActivityMonitor and UserInputIdleDetector,
/// tracking frontmost window changes, system sleep/wake, display lock/unlock,
/// and physical HID events.
public final class ZoidZeroLiveTracker: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.mavoid.zoidlockin",
        category: "ZoidZeroLiveTracker"
    )

    public static let shared = ZoidZeroLiveTracker()

    /// Whitelist of productive bundle identifiers adapted from Zoid 0 & Zoid Lock In.
    public static let defaultProductiveBundlePrefixes: Set<String> = [
        "com.apple.dt.Xcode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.sublimetext",
        "md.obsidian",
        "notion.id",
        "com.linear",
        "com.figma.Desktop",
        "com.github.GitHubClient",
        "com.fournova.Tower",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.openai.chat"
    ]

    private let lock = NSLock()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var idleCheckTimer: DispatchSourceTimer?
    private var isStarted = false
    private var currentApp: TrackedAppIdentity?
    private var activePauseReasons: Set<TrackingPauseReason> = []
    private let idleThreshold: TimeInterval
    private let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    /// Callback invoked when the productive state changes.
    /// isProductiveAndActive is true when frontmost is a productive app AND user is not idle/locked/sleeping.
    public var onProductiveStateChanged: (@Sendable (_ isProductiveAndActive: Bool, _ app: TrackedAppIdentity?) -> Void)?

    public init(idleThreshold: TimeInterval = 90) {
        self.idleThreshold = idleThreshold
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

    private func handleApplicationActivation(_ app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? "Unknown"
        let isProductive = Self.isProductive(bundleIdentifier: bundleId)
        let identity = TrackedAppIdentity(
            bundleIdentifier: bundleId,
            displayName: name,
            isProductive: isProductive
        )

        lock.lock()
        currentApp = identity
        if !isProductive {
            activePauseReasons.insert(.nonProductiveApp)
        } else {
            activePauseReasons.remove(.nonProductiveApp)
        }
        let productiveAndActive = isProductive && activePauseReasons.isEmpty
        let callback = onProductiveStateChanged
        lock.unlock()

        callback?(productiveAndActive, identity)
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

    public static func isProductive(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        for prefix in defaultProductiveBundlePrefixes {
            if bundleIdentifier.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }
}
