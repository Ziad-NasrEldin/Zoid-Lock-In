import Foundation
import ZoidLockInCore

/// Codable snapshot of enforcement policy for Slice 2 XPC.
///
/// The daemon owns expiry on monotonic time. User-space SQLite must never be
/// the source of truth for whether a pass is active.
public struct EnforcementPolicySnapshot: Sendable, Equatable, Codable {
    public var mode: EnforcementMode
    public var blacklistedSuffixes: [String]
    public var whitelistedSuffixes: [String]
    public var processTargetNames: [String]
    public var inspectedPorts: [UInt16]
    public var processScanIntervalSeconds: TimeInterval

    public init(
        mode: EnforcementMode = .hard,
        blacklistedSuffixes: [String] = DomainFilterRules.defaultBlacklist,
        whitelistedSuffixes: [String] = [],
        processTargetNames: [String] = ProcessTargetMatcher.defaultTargets,
        inspectedPorts: [UInt16] = Array(EnforcementPolicy.defaultInspectedPorts).sorted(),
        processScanIntervalSeconds: TimeInterval = EnforcementPolicy.defaultScanIntervalSeconds
    ) {
        self.mode = mode
        self.blacklistedSuffixes = blacklistedSuffixes
        self.whitelistedSuffixes = whitelistedSuffixes
        self.processTargetNames = processTargetNames
        self.inspectedPorts = inspectedPorts
        self.processScanIntervalSeconds = processScanIntervalSeconds
    }

    public init(_ policy: EnforcementPolicy) {
        self.mode = policy.mode
        self.blacklistedSuffixes = policy.domainRules.blacklistedSuffixes
        self.whitelistedSuffixes = policy.domainRules.whitelistedSuffixes
        self.processTargetNames = policy.processMatcher.targetNames
        self.inspectedPorts = Array(policy.inspectedPorts).sorted()
        self.processScanIntervalSeconds = policy.processScanIntervalSeconds
    }

    public func makePolicy() -> EnforcementPolicy {
        EnforcementPolicy(
            domainRules: DomainFilterRules(
                blacklistedSuffixes: blacklistedSuffixes,
                whitelistedSuffixes: whitelistedSuffixes
            ),
            processMatcher: ProcessTargetMatcher(targetNames: processTargetNames),
            processScanIntervalSeconds: processScanIntervalSeconds,
            inspectedPorts: Set(inspectedPorts),
            mode: mode
        )
    }
}

public struct EnforcementStatus: Sendable, Equatable, Codable {
    public var mode: EnforcementMode
    public var isLockedDown: Bool
    public var activePassKind: PassKind?
    public var remainingPassSeconds: Int

    public init(
        mode: EnforcementMode = .hard,
        isLockedDown: Bool = true,
        activePassKind: PassKind? = nil,
        remainingPassSeconds: Int = 0
    ) {
        self.mode = mode
        self.isLockedDown = isLockedDown
        self.activePassKind = activePassKind
        self.remainingPassSeconds = remainingPassSeconds
    }
}

/// Slice 2 XPC seam. The LaunchDaemon implements this; the filter sysex does not.
///
/// NSXPC mapping pins Team ID via `ZoidLockInIdentity.xpcClientRequirement(teamID:)`.
/// `MachServices` is advertised because `audit_token_t` validation ships with this slice.
public protocol ZoidLockInEnforcementServicing: Sendable {
    func applyPolicy(_ snapshot: EnforcementPolicySnapshot) async throws
    func openPass(kind: PassKind, durationSeconds: Int, nonce: String) async throws
    func revokePass(kind: PassKind) async throws
    func queryStatus() async throws -> EnforcementStatus
    func engageEmergencySafetyValve() async throws
    func heartbeat() async throws
}
