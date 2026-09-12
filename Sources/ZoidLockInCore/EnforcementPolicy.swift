import Foundation

/// Combined enforcement policy applied by the privileged daemon.
public struct EnforcementPolicy: Sendable, Equatable {
    public var domainRules: DomainFilterRules
    public var processMatcher: ProcessTargetMatcher
    public var processScanIntervalSeconds: TimeInterval
    public var inspectedTCPPorts: Set<UInt16>

    public static let defaultTCPPorts: Set<UInt16> = [80, 443]
    public static let defaultScanIntervalSeconds: TimeInterval = 1.5

    public init(
        domainRules: DomainFilterRules = DomainFilterRules(),
        processMatcher: ProcessTargetMatcher = ProcessTargetMatcher(),
        processScanIntervalSeconds: TimeInterval = EnforcementPolicy.defaultScanIntervalSeconds,
        inspectedTCPPorts: Set<UInt16> = EnforcementPolicy.defaultTCPPorts
    ) {
        self.domainRules = domainRules
        self.processMatcher = processMatcher
        self.processScanIntervalSeconds = processScanIntervalSeconds
        self.inspectedTCPPorts = inspectedTCPPorts
    }

    public static let lockedDown = EnforcementPolicy()

    public func shouldInspect(port: UInt16) -> Bool {
        inspectedTCPPorts.contains(port)
    }
}
