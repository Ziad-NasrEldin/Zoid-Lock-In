import Foundation

/// One concurrent daemon pass as published to the filter and the menu bar.
public struct ActivePassStatus: Sendable, Equatable, Codable {
    public var kind: PassKind
    public var remainingSeconds: Int

    public init(kind: PassKind, remainingSeconds: Int) {
        self.kind = kind
        self.remainingSeconds = remainingSeconds
    }
}

/// Query-only snapshot of daemon enforcement state for the Network Extension.
///
/// The filter may **read** this snapshot. It must never write pass state, open
/// passes, or call control RPCs. UI processes must never write this file.
public struct FilterEnforcementSnapshot: Sendable, Equatable, Codable {
    public var policy: EnforcementPolicySnapshot
    public var isPassActive: Bool
    public var activePassKind: PassKind?
    public var remainingPassSeconds: Int
    public var isLockedDown: Bool
    public var activePasses: [ActivePassStatus]

    public init(
        policy: EnforcementPolicySnapshot = EnforcementPolicySnapshot(),
        isPassActive: Bool = false,
        activePassKind: PassKind? = nil,
        remainingPassSeconds: Int = 0,
        isLockedDown: Bool = true,
        activePasses: [ActivePassStatus] = []
    ) {
        self.policy = policy
        self.isPassActive = isPassActive
        self.activePassKind = activePassKind
        self.remainingPassSeconds = remainingPassSeconds
        self.isLockedDown = isLockedDown
        self.activePasses = Self.normalizedPasses(
            activePasses: activePasses,
            activePassKind: activePassKind,
            remainingPassSeconds: remainingPassSeconds
        )
    }

    public init(
        enforcementPolicy: EnforcementPolicy,
        isPassActive: Bool,
        activePassKind: PassKind?,
        remainingPassSeconds: Int,
        isLockedDown: Bool,
        activePasses: [ActivePassStatus] = []
    ) {
        self.policy = EnforcementPolicySnapshot(enforcementPolicy)
        self.isPassActive = isPassActive
        self.activePassKind = activePassKind
        self.remainingPassSeconds = remainingPassSeconds
        self.isLockedDown = isLockedDown
        self.activePasses = Self.normalizedPasses(
            activePasses: activePasses,
            activePassKind: activePassKind,
            remainingPassSeconds: remainingPassSeconds
        )
    }

    public var enforcementPolicy: EnforcementPolicy {
        policy.makePolicy()
    }

    public var activePassKinds: [PassKind] {
        activePasses.map(\.kind)
    }

    public var resolvedPassKinds: Set<PassKind> {
        let fromPasses = Set(activePasses.map(\.kind))
        if !fromPasses.isEmpty {
            return fromPasses
        }
        return Set([activePassKind].compactMap { $0 })
    }

    public static let lockedDown = FilterEnforcementSnapshot()

    private static func normalizedPasses(
        activePasses: [ActivePassStatus],
        activePassKind: PassKind?,
        remainingPassSeconds: Int
    ) -> [ActivePassStatus] {
        if !activePasses.isEmpty {
            return activePasses.sorted { $0.kind < $1.kind }
        }
        if let activePassKind {
            return [ActivePassStatus(kind: activePassKind, remainingSeconds: remainingPassSeconds)]
        }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case policy
        case isPassActive
        case activePassKind
        case remainingPassSeconds
        case isLockedDown
        case activePasses
        case activePassKinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPolicy = try container.decode(EnforcementPolicySnapshot.self, forKey: .policy)
        let decodedPassActive = try container.decode(Bool.self, forKey: .isPassActive)
        var decodedKind = try container.decodeIfPresent(PassKind.self, forKey: .activePassKind)
        let decodedRemaining = try container.decodeIfPresent(Int.self, forKey: .remainingPassSeconds) ?? 0
        let decodedLocked = try container.decodeIfPresent(Bool.self, forKey: .isLockedDown) ?? true
        let decodedPasses: [ActivePassStatus]
        if let passes = try container.decodeIfPresent([ActivePassStatus].self, forKey: .activePasses),
           !passes.isEmpty {
            decodedPasses = passes.sorted { $0.kind < $1.kind }
        } else if let kinds = try container.decodeIfPresent([PassKind].self, forKey: .activePassKinds),
                  !kinds.isEmpty {
            decodedPasses = kinds
                .map { kind in ActivePassStatus(kind: kind, remainingSeconds: decodedRemaining) }
                .sorted { $0.kind < $1.kind }
            if decodedKind == nil {
                decodedKind = FilterFlowEvaluator.primary(of: Set(kinds))
            }
        } else if let decodedKind {
            decodedPasses = [ActivePassStatus(kind: decodedKind, remainingSeconds: decodedRemaining)]
        } else {
            decodedPasses = []
        }
        policy = decodedPolicy
        isPassActive = decodedPassActive
        activePassKind = decodedKind
        remainingPassSeconds = decodedRemaining
        isLockedDown = decodedLocked
        activePasses = decodedPasses
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
        try container.encode(isPassActive, forKey: .isPassActive)
        try container.encodeIfPresent(activePassKind, forKey: .activePassKind)
        try container.encode(remainingPassSeconds, forKey: .remainingPassSeconds)
        try container.encode(isLockedDown, forKey: .isLockedDown)
        try container.encode(activePasses, forKey: .activePasses)
        try container.encode(activePassKinds, forKey: .activePassKinds)
    }
}

/// Query-only reader used by `FilterFlowEvaluator` and `ContentFilterProvider`.
public protocol FilterEnforcementStatusReading: Sendable {
    func currentFilterSnapshot() -> FilterEnforcementSnapshot
}

/// Daemon-side publisher. Only the privileged process may write.
public protocol FilterEnforcementStatusPublishing: Sendable {
    func publish(_ snapshot: FilterEnforcementSnapshot)
}

/// Evaluates flows against a query-only daemon snapshot. Used by
/// `ContentFilterProvider` and by tests that cannot construct `NEFilterDataProvider`.
public struct ContentFilterEngine: Sendable {
    public var statusReader: (any FilterEnforcementStatusReading)?
    public var fallbackPolicy: EnforcementPolicy

    public init(
        statusReader: (any FilterEnforcementStatusReading)? = nil,
        fallbackPolicy: EnforcementPolicy = .lockedDown
    ) {
        self.statusReader = statusReader
        self.fallbackPolicy = fallbackPolicy
    }

    public func currentSnapshot() -> FilterEnforcementSnapshot {
        if let statusReader {
            return statusReader.currentFilterSnapshot()
        }
        return FilterEnforcementSnapshot(
            enforcementPolicy: fallbackPolicy,
            isPassActive: false,
            activePassKind: nil,
            remainingPassSeconds: 0,
            isLockedDown: fallbackPolicy.mode == .hard
        )
    }

    public func verdict(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol
    ) -> FilterVerdict {
        FilterFlowEvaluator(snapshot: currentSnapshot()).verdict(
            for: FilterFlowRequest(hostname: hostname, port: port, transport: transport)
        )
    }
}

/// This is the wired Slice 2 seam: never UI-written, never a control RPC.
public final class FilterPolicyHub: FilterEnforcementStatusReading, FilterEnforcementStatusPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: FilterEnforcementSnapshot

    public init(snapshot: FilterEnforcementSnapshot = .lockedDown) {
        self.snapshot = snapshot
    }

    public func currentFilterSnapshot() -> FilterEnforcementSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func publish(_ snapshot: FilterEnforcementSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }
}

/// Daemon-written, filter-read status file. Default location is the daemon
/// storage directory (`/var/db/zoidlockin/filter_status.json` in production).
public final class FileFilterStatusStore: FilterEnforcementStatusReading, FilterEnforcementStatusPublishing, @unchecked Sendable {
    public static let defaultFileName = "filter_status.json"

    public let fileURL: URL
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        directory: URL,
        fileName: String = FileFilterStatusStore.defaultFileName,
        fileManager: FileManager = .default
    ) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func currentFilterSnapshot() -> FilterEnforcementSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadLocked()) ?? .lockedDown
    }

    public func publish(_ snapshot: FilterEnforcementSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        try? persistLocked(snapshot)
    }

    private func loadLocked() throws -> FilterEnforcementSnapshot {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FilterEnforcementSnapshot.self, from: data)
    }

    private func persistLocked(_ snapshot: FilterEnforcementSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
