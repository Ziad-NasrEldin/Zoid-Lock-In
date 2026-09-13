import Foundation

/// Soft calibration versus hard lockdown. Slice 9 uses `.soft`; Slice 1 defaults to `.hard`.
public enum EnforcementMode: String, Sendable, Equatable, Codable {
    case hard
    case soft
}

/// Combined enforcement policy applied by the privileged daemon and the filter sysex.
public struct EnforcementPolicy: Sendable, Equatable {
    public var domainRules: DomainFilterRules
    public var processMatcher: ProcessTargetMatcher
    public var processScanIntervalSeconds: TimeInterval
    public var inspectedPorts: Set<UInt16>
    public var mode: EnforcementMode

    public static let defaultInspectedPorts: Set<UInt16> = [80, 443, 8080, 1080]
    public static let defaultScanIntervalSeconds: TimeInterval = 1.5

    public init(
        domainRules: DomainFilterRules = DomainFilterRules(),
        processMatcher: ProcessTargetMatcher = ProcessTargetMatcher(),
        processScanIntervalSeconds: TimeInterval = EnforcementPolicy.defaultScanIntervalSeconds,
        inspectedPorts: Set<UInt16> = EnforcementPolicy.defaultInspectedPorts,
        mode: EnforcementMode = .hard
    ) {
        self.domainRules = domainRules
        self.processMatcher = processMatcher
        self.processScanIntervalSeconds = processScanIntervalSeconds
        self.inspectedPorts = inspectedPorts
        self.mode = mode
    }

    public static let lockedDown = EnforcementPolicy()

    /// Emergency overlay: whitelist every blacklisted suffix and pause kills.
    public func relaxingForActivePass() -> EnforcementPolicy {
        overlay(for: .emergency)
    }

    /// Kind-scoped overlay. Food/phone/streaming keep process kills; gaming
    /// pauses kills without opening food or streaming domains.
    public func overlay(for kind: PassKind) -> EnforcementPolicy {
        switch kind {
        case .emergency:
            return EnforcementPolicy(
                domainRules: domainRules.withWhitelist(domainRules.blacklistedSuffixes),
                processMatcher: processMatcher,
                processScanIntervalSeconds: processScanIntervalSeconds,
                inspectedPorts: inspectedPorts,
                mode: .soft
            )
        case .food, .phone, .streaming:
            return EnforcementPolicy(
                domainRules: domainRules.allowing(suffixes: kind.relaxedDomainSuffixes),
                processMatcher: processMatcher,
                processScanIntervalSeconds: processScanIntervalSeconds,
                inspectedPorts: inspectedPorts,
                mode: .hard
            )
        case .gaming:
            return EnforcementPolicy(
                domainRules: domainRules,
                processMatcher: processMatcher,
                processScanIntervalSeconds: processScanIntervalSeconds,
                inspectedPorts: inspectedPorts,
                mode: .soft
            )
        }
    }

    /// True for HTTP, HTTPS, HTTP/3 (UDP/443), and common local proxy ports.
    public func shouldInspect(port: UInt16) -> Bool {
        inspectedPorts.contains(port)
    }

    public func flowVerdict(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol,
        activePassKind: PassKind? = nil
    ) -> FilterVerdict {
        FilterFlowEvaluator(policy: self, activePassKind: activePassKind).verdict(
            for: FilterFlowRequest(hostname: hostname, port: port, transport: transport)
        )
    }
}
