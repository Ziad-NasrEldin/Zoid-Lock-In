import Darwin
import Foundation
import Network
import NetworkExtension
import ZoidLockInCore

/// System-extension `NEFilterDataProvider` that drops outbound TCP and UDP flows
/// to blacklisted domains unless a **kind-scoped** daemon pass relaxes them.
///
/// This class is the Network Extension **principal class**. It must not be
/// hosted in the LaunchDaemon. Filter status is **query-only**: inject a
/// `FilterEnforcementStatusReading` (hub or daemon-written file). Never read
/// UI-written shared files.
public final class ContentFilterProvider: NEFilterDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _policy: EnforcementPolicy
    private let engine: ContentFilterEngine

    public var policy: EnforcementPolicy {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _policy
        }
        set {
            lock.lock()
            _policy = newValue
            lock.unlock()
        }
    }

    public init(
        policy: EnforcementPolicy = .lockedDown,
        statusReader: (any FilterEnforcementStatusReading)? = nil
    ) {
        self._policy = policy
        self.engine = ContentFilterEngine(statusReader: statusReader, fallbackPolicy: policy)
        super.init()
    }

    public func currentSnapshot() -> FilterEnforcementSnapshot {
        var engine = engine
        lock.lock()
        engine.fallbackPolicy = _policy
        lock.unlock()
        return engine.currentSnapshot()
    }

    /// Evaluates a flow against the live daemon snapshot (or the local policy).
    public func verdict(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol
    ) -> FilterVerdict {
        var engine = engine
        lock.lock()
        engine.fallbackPolicy = _policy
        lock.unlock()
        return engine.verdict(hostname: hostname, port: port, transport: transport)
    }

    override public func startFilter(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override public func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override public func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        let transport = Self.transport(from: socketFlow.socketProtocol)
        let port = Self.remotePort(from: socketFlow)
        let hostname = Self.hostname(from: socketFlow)
        return Self.mapVerdict(verdict(hostname: hostname, port: port, transport: transport))
    }

    /// Pure decision helper used by unit tests without constructing socket flows.
    public static func networkVerdict(
        forHostname hostname: String?,
        rules: DomainFilterRules
    ) -> NEFilterNewFlowVerdict {
        let policy = EnforcementPolicy(domainRules: rules)
        return networkVerdict(
            hostname: hostname,
            port: 443,
            transport: .tcp,
            policy: policy
        )
    }

    public static func networkVerdict(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol,
        policy: EnforcementPolicy,
        activePassKind: PassKind? = nil
    ) -> NEFilterNewFlowVerdict {
        mapVerdict(
            FilterFlowEvaluator(policy: policy, activePassKind: activePassKind).verdict(
                for: FilterFlowRequest(hostname: hostname, port: port, transport: transport)
            )
        )
    }

    public static func networkVerdict(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol,
        snapshot: FilterEnforcementSnapshot
    ) -> NEFilterNewFlowVerdict {
        mapVerdict(
            FilterFlowEvaluator(snapshot: snapshot).verdict(
                for: FilterFlowRequest(hostname: hostname, port: port, transport: transport)
            )
        )
    }

    /// Maps core `FilterVerdict` values onto Network Extension verdicts.
    public static func mapVerdict(_ verdict: FilterVerdict) -> NEFilterNewFlowVerdict {
        switch verdict {
        case .allow:
            return .allow()
        case .drop:
            return .drop()
        }
    }

    public static func transport(from socketProtocol: Int32) -> TransportProtocol {
        switch socketProtocol {
        case IPPROTO_TCP:
            return .tcp
        case IPPROTO_UDP:
            return .udp
        default:
            return .other
        }
    }

    public static func hostname(from flow: NEFilterSocketFlow) -> String? {
        if let remoteHostname = flow.remoteHostname, !remoteHostname.isEmpty {
            return remoteHostname
        }

        if let urlHost = flow.url?.host, !urlHost.isEmpty {
            return urlHost
        }

        if #available(macOS 15.0, *) {
            if let endpoint = flow.remoteFlowEndpoint,
               case .hostPort(let host, _) = endpoint {
                switch host {
                case .name(let name, _):
                    return name
                case .ipv4, .ipv6:
                    return nil
                @unknown default:
                    return nil
                }
            }
        }

        return nil
    }

    public static func remotePort(from flow: NEFilterSocketFlow) -> UInt16? {
        if #available(macOS 15.0, *) {
            guard let endpoint = flow.remoteFlowEndpoint else {
                return nil
            }

            if case .hostPort(_, let port) = endpoint {
                return port.rawValue
            }
        }

        return nil
    }
}
