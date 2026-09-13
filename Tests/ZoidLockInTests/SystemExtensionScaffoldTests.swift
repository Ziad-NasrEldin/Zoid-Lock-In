import Foundation
import NetworkExtension
import Testing
import ZoidLockInCore
import ZoidLockInFilterExtension
import ZoidLockInIPC

@Suite("System extension and Slice 2 XPC seams")
struct SystemExtensionScaffoldTests {
    @Test("filter bundle identifiers are distinct from the LaunchDaemon")
    func bundleIdentifiersAreSeparated() {
        #expect(
            ZoidLockInIdentity.filterSystemExtensionBundleIdentifier
                != ZoidLockInIdentity.daemonLabel
        )
        #expect(
            ZoidLockInIdentity.filterDataProviderBundleIdentifier
                == "com.mavoid.zoidlockin.filter"
        )
        #expect(ZoidLockInIdentity.daemonLabel == "com.mavoid.zoidlockin.helper")
        #expect(
            ZoidLockInIPCIdentity.filterSystemExtensionBundleIdentifier
                == ZoidLockInIdentity.filterSystemExtensionBundleIdentifier
        )
        #expect(
            ZoidLockInIdentity.xpcClientRequirementTemplate.contains("subject.OU")
        )
        #expect(
            !ZoidLockInIdentity.xpcClientRequirementTemplate.hasPrefix("anchor apple generic\"")
        )
    }

    @Test("sysex Info.plist names the filter providers and filter bundle id")
    func filterInfoPlistIsScaffolded() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ZoidLockInFilterExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")

        let data = try Data(contentsOf: plistURL)
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let dictionary = try #require(parsed as? [String: Any])

        #expect(dictionary["CFBundleIdentifier"] as? String == "com.mavoid.zoidlockin.filter")
        #expect(dictionary["CFBundlePackageType"] as? String == "SYSX")

        let networkExtension = try #require(dictionary["NetworkExtension"] as? [String: Any])
        let classes = try #require(networkExtension["NEProviderClasses"] as? [String: String])
        #expect(classes["com.apple.networkextension.filter-data"]?.contains("ContentFilterProvider") == true)
        #expect(classes["com.apple.networkextension.filter-control"] == nil)
    }

    @Test("sysex entitlements request the content-filter system-extension capability")
    func filterEntitlementsAreScaffolded() throws {
        let entitlementsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ZoidLockInFilterExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("ZoidLockInFilterExtension.entitlements")

        let data = try Data(contentsOf: entitlementsURL)
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let dictionary = try #require(parsed as? [String: Any])
        let capabilities = try #require(
            dictionary["com.apple.developer.networking.networkextension"] as? [String]
        )
        #expect(capabilities.contains("content-filter-provider-systemextension"))
    }

    @Test("activation configuration points at the filter sysex, not the daemon")
    func activationUsesFilterBundle() {
        let activation = ContentFilterActivation()
        let configuration = activation.makeProviderConfiguration()

        #expect(configuration.filterSockets)
        #expect(!configuration.filterPackets)
        #expect(
            configuration.filterDataProviderBundleIdentifier
                == ZoidLockInIdentity.filterDataProviderBundleIdentifier
        )
        #expect(
            configuration.filterDataProviderBundleIdentifier
                != ZoidLockInIdentity.daemonLabel
        )
        #expect(
            ContentFilterActivation.systemExtensionBundleIdentifier
                == "com.mavoid.zoidlockin.filter"
        )
    }

    @Test("policy snapshot round-trips through the Slice 2 XPC DTO")
    func policySnapshotRoundTrip() {
        let policy = EnforcementPolicy.lockedDown
        let snapshot = EnforcementPolicySnapshot(policy)
        let restored = snapshot.makePolicy()

        #expect(restored.mode == .hard)
        #expect(restored.inspectedPorts == policy.inspectedPorts)
        #expect(Set(snapshot.inspectedPorts).contains(443))
        #expect(Set(snapshot.inspectedPorts).contains(8080))
    }
}

@Suite("Filter flow evaluator")
struct FilterFlowEvaluatorTests {
    @Test("UDP 443 is inspected under lockdown")
    func inspectsUDP443() {
        let evaluator = FilterFlowEvaluator(policy: .lockedDown)
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 443, transport: .udp)
            ) == .drop
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: nil, port: 443, transport: .udp)
            ) == .drop
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: "github.com", port: 443, transport: .udp)
            ) == .allow
        )
    }

    @Test("active emergency pass allows blacklisted and unverified inspected flows")
    func activePassAllowsInspectedFlows() {
        let evaluator = FilterFlowEvaluator(policy: .lockedDown, activePassKind: .emergency)
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 443, transport: .udp)
            ) == .allow
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: nil, port: 443, transport: .udp)
            ) == .allow
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: "talabat.com", port: 443, transport: .tcp)
            ) == .allow
        )
    }

    @Test("proxy ports 8080 and 1080 fail closed without a hostname")
    func proxyPortsFailClosed() {
        let evaluator = FilterFlowEvaluator(policy: .lockedDown)
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: nil, port: 8080, transport: .tcp)
            ) == .drop
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: nil, port: 1080, transport: .tcp)
            ) == .drop
        )
        #expect(
            evaluator.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 8080, transport: .tcp)
            ) == .drop
        )
    }
}
