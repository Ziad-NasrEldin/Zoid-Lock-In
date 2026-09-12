import Foundation

/// Codable snapshot of enforcement policy for Slice 2 XPC.
///
/// The daemon owns expiry on monotonic-continuous time. User-space SQLite must
/// never be the source of truth for whether a pass is active.
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

    /// Validates XPC-supplied policy. Empty process lists, names outside the
    /// baked allowlist, and snapshots that omit essential inspected ports are
    /// rejected so an admitted client cannot disable the sentinel or filter.
    public func validatedPolicy() throws -> EnforcementPolicy {
        let incomingTargets = Set(
            processTargetNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let requiredTargets = Set(ProcessTargetMatcher.defaultTargets.map { $0.lowercased() })

        if incomingTargets.isEmpty {
            throw EnforcementControlError.policyRejected("process target list must not be empty")
        }
        if !incomingTargets.isSubset(of: requiredTargets) {
            throw EnforcementControlError.policyRejected(
                "process target list contains names outside the baked allowlist"
            )
        }
        if incomingTargets != requiredTargets {
            throw EnforcementControlError.policyRejected(
                "process target list must not omit baked sentinel targets"
            )
        }

        let incomingPorts = Set(inspectedPorts)
        let essential = EnforcementPolicy.defaultInspectedPorts
        if !essential.isSubset(of: incomingPorts) {
            throw EnforcementControlError.policyRejected(
                "inspected ports must include 80, 443, 8080, and 1080"
            )
        }

        if blacklistedSuffixes
            .map({ DomainFilterRules.normalize($0) })
            .filter({ !$0.isEmpty })
            .isEmpty {
            throw EnforcementControlError.policyRejected("domain blacklist must not be empty")
        }

        // Bake defaults: caller-supplied whitelist is ignored (pass overlay only).
        var policy = EnforcementPolicy.lockedDown
        policy.mode = .hard
        policy.inspectedPorts = essential.union(incomingPorts)
        return policy
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
