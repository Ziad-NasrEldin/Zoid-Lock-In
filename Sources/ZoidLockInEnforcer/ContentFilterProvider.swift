import Foundation
import Network
import NetworkExtension
import ZoidLockInCore

/// Prototype `NEFilterDataProvider` that drops outbound TCP flows to blacklisted domains.
///
/// Slice 1 inspects ports 80/443 and resolves hostnames from the socket flow's
/// remote hostname (SNI / DNS metadata exposed by the Network Extension stack).
open class ContentFilterProvider: NEFilterDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _policy: EnforcementPolicy

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

    public init(policy: EnforcementPolicy = .lockedDown) {
        self._policy = policy
        super.init()
    }

    override open func startFilter(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override open func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override open func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        // Only enforce on TCP socket flows.
        guard socketFlow.socketProtocol == IPPROTO_TCP else {
            return .allow()
        }

        let currentPolicy = policy
        let port = Self.remotePort(from: socketFlow)

        // When the remote port is known, only inspect HTTP/HTTPS.
        // When unavailable at handleNewFlow time, still evaluate hostname (fail-closed).
        if let port, !currentPolicy.shouldInspect(port: port) {
            return .allow()
        }

        let hostname = Self.hostname(from: socketFlow)
        return Self.networkVerdict(
            forHostname: hostname,
            rules: currentPolicy.domainRules
        )
    }

    /// Pure decision helper used by unit tests without constructing socket flows.
    public static func networkVerdict(
        forHostname hostname: String?,
        rules: DomainFilterRules
    ) -> NEFilterNewFlowVerdict {
        mapVerdict(rules.verdict(forHostname: hostname))
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
