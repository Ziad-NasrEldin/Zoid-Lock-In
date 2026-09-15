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
///
/// Passes are **kind-scoped** and may be concurrent. `.emergency` allows every
/// inspected flow, including unverified hostnames. Concurrent amenity kinds
/// union their suffixes; unrelated blacklisted hosts and unverified identities
/// still drop. When any one pass expires, its suffixes leave the union immediately.
public struct FilterFlowEvaluator: Sendable, Equatable {
    public var policy: EnforcementPolicy
    public var activePassKind: PassKind?
    public var activePassKinds: Set<PassKind>

    public init(policy: EnforcementPolicy = .lockedDown, activePassKind: PassKind? = nil) {
        self.policy = policy
        self.activePassKind = activePassKind
        self.activePassKinds = Set([activePassKind].compactMap { $0 })
    }

    public init(policy: EnforcementPolicy, activePassKinds: Set<PassKind>) {
        self.policy = policy
        self.activePassKinds = activePassKinds
        self.activePassKind = Self.primary(of: activePassKinds)
    }

    public init(snapshot: FilterEnforcementSnapshot) {
        self.policy = snapshot.enforcementPolicy
        let kinds = snapshot.resolvedPassKinds
        self.activePassKinds = kinds
        self.activePassKind = snapshot.activePassKind ?? Self.primary(of: kinds)
    }

    public func verdict(for request: FilterFlowRequest) -> FilterVerdict {
        let hard = hardVerdict(for: request)
        if policy.mode == .calibration, hard == .drop {
            return .softInfraction
        }
        return hard
    }

    /// Hard-lockdown decision before calibration remaps drops to warnings.
    public func hardVerdict(for request: FilterFlowRequest) -> FilterVerdict {
        switch request.transport {
        case .other:
            return .allow
        case .tcp, .udp:
            let kinds = effectiveKinds
            if kinds.contains(.emergency) {
                return .allow
            }

            if let port = request.port, !policy.shouldInspect(port: port) {
                return .allow
            }

            let extra = kinds.flatMap(\.relaxedDomainSuffixes)
            let rules = policy.domainRules.allowing(suffixes: extra)
            return rules.verdict(forHostname: request.hostname)
        }
    }

    public var effectiveKinds: Set<PassKind> {
        if !activePassKinds.isEmpty {
            return activePassKinds
        }
        return Set([activePassKind].compactMap { $0 })
    }

    public static func primary(of kinds: Set<PassKind>) -> PassKind? {
        kinds.sorted().first
    }
}
