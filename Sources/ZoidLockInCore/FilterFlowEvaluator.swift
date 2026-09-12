import Foundation

/// Transport used by an outbound socket flow.
public enum TransportProtocol: String, Sendable, Equatable, Codable {
    case tcp
    case udp
    case other
}

/// Inputs for a pure content-filter decision (no Network Extension types).
public struct FilterFlowRequest: Sendable, Equatable {
    public var hostname: String?
    public var port: UInt16?
    public var transport: TransportProtocol

    public init(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol
    ) {
        self.hostname = hostname
        self.port = port
        self.transport = transport
    }
}

/// Pure evaluator used by the system-extension provider and by unit tests.
///
/// Inspected TCP/UDP ports fail closed when the hostname is missing, empty, or
/// an IP literal. UDP/443 (QUIC / HTTP/3) is inspected with the same rule so it
/// cannot bypass the TCP-only matcher.
public struct FilterFlowEvaluator: Sendable, Equatable {
    public var policy: EnforcementPolicy

    public init(policy: EnforcementPolicy = .lockedDown) {
        self.policy = policy
    }

    public func verdict(for request: FilterFlowRequest) -> FilterVerdict {
        switch request.transport {
        case .other:
            return .allow
        case .tcp, .udp:
            if let port = request.port, !policy.shouldInspect(port: port) {
                return .allow
            }

            return policy.domainRules.verdict(forHostname: request.hostname)
        }
    }
}
