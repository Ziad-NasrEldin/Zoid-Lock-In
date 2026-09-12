import Darwin
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInIPC

@Suite("XPC audit token gatekeeper")
struct XPCAuditTokenGatekeeperTests {
    private let teamID = "ABCD123456"
    private let identifier = ZoidLockInIdentity.applicationBundleIdentifier

    private func token(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: AuditTokenExtraction.expectedByteCount)
    }

    private func gatekeeper(
        identities: [Data: InspectedCodeIdentity],
        requirementResults: [Data: Bool] = [:]
    ) -> XPCAuditTokenGatekeeper {
        XPCAuditTokenGatekeeper(
            teamID: teamID,
            identifier: identifier,
            inspector: StubGuestInspector(
                identities: identities,
                requirementResults: requirementResults
            )
        )
    }

    @Test("Team-ID-pinned requirement string contains subject.OU and the app identifier")
    func requirementIsTeamIDPinned() {
        let requirement = ZoidLockInIdentity.xpcClientRequirement(teamID: teamID)
        #expect(CodeRequirement.isTeamIDPinned(requirement))
        #expect(requirement.contains("subject.OU"))
        #expect(requirement.contains(teamID))
        #expect(requirement.contains(identifier))
        #expect(
            !CodeRequirement.isTeamIDPinned(
                "identifier \"com.mavoid.zoidlockin\" and anchor apple generic"
            )
        )
        #expect(ZoidLockInIdentity.xpcClientRequirementTemplate.contains("subject.OU"))
    }

    @Test("accepts a signed client that matches Team ID and bundle identifier")
    func acceptsAuthorizedClient() {
        let audit = token(1)
        let identity = InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: teamID,
            isSignatureValid: true
        )
        let decision = gatekeeper(identities: [audit: identity]).evaluate(auditToken: audit, pid: 4242)
        #expect(decision.accepted)
        #expect(decision.identity == identity)
        #expect(decision.rejection == nil)
    }

    @Test("rejects callers with a mismatched Team ID")
    func rejectsTeamIDMismatch() {
        let audit = token(2)
        let identity = InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: "EVILTEAMID",
            isSignatureValid: true
        )
        let decision = gatekeeper(
            identities: [audit: identity],
            requirementResults: [audit: true]
        ).evaluate(auditToken: audit, pid: 99)
        #expect(!decision.accepted)
        #expect(
            decision.rejection
                == .teamIdentifierMismatch(found: "EVILTEAMID", expected: teamID)
        )
    }

    @Test("rejects callers with a mismatched bundle identifier")
    func rejectsBundleIDMismatch() {
        let audit = token(3)
        let identity = InspectedCodeIdentity(
            signingIdentifier: "com.apple.finder",
            teamIdentifier: teamID,
            isSignatureValid: true
        )
        let decision = gatekeeper(
            identities: [audit: identity],
            requirementResults: [audit: true]
        ).evaluate(auditToken: audit, pid: 88)
        #expect(!decision.accepted)
        #expect(
            decision.rejection
                == .identifierMismatch(found: "com.apple.finder", expected: identifier)
        )
    }

    @Test("rejects unsigned or spoofed signatures that claim the Zoid identity")
    func rejectsSpoofedUnsignedCaller() {
        let audit = token(4)
        let identity = InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: teamID,
            isSignatureValid: false
        )
        let decision = gatekeeper(identities: [audit: identity]).evaluate(auditToken: audit, pid: 1)
        #expect(!decision.accepted)
        #expect(decision.rejection == .signatureInvalid)
    }

    @Test("rejects unknown audit tokens rather than falling back to PID")
    func rejectsUnknownAuditToken() {
        let known = token(5)
        let spoofed = token(6)
        let identity = InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: teamID,
            isSignatureValid: true
        )
        let decision = gatekeeper(identities: [known: identity]).evaluate(
            auditToken: spoofed,
            pid: 4242
        )
        #expect(!decision.accepted)
        #expect(decision.rejection == .guestCodeUnavailable)
    }

    @Test("rejects truncated or empty audit tokens")
    func rejectsMissingAuditToken() {
        let gatekeeper = gatekeeper(identities: [:])
        #expect(!gatekeeper.evaluate(auditToken: Data()).accepted)
        #expect(!gatekeeper.evaluate(auditToken: Data([0, 1, 2, 3])).accepted)
        #expect(gatekeeper.evaluate(auditToken: Data()).rejection == .missingAuditToken)
    }

    @Test("rejects callers that fail SecCodeCheckValidity against the requirement")
    func rejectsFailedRequirementCheck() {
        let audit = token(7)
        let identity = InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: teamID,
            isSignatureValid: true
        )
        let decision = gatekeeper(
            identities: [audit: identity],
            requirementResults: [audit: false]
        ).evaluate(auditToken: audit, pid: 7)
        #expect(!decision.accepted)
        #expect(decision.rejection == .unauthorized)
    }

    @Test("current process is not an authorized Zoid Lock In client")
    func rejectsUnauthorizedCurrentProcess() throws {
        let token = try AuditTokenExtraction.currentProcess()
        #expect(token.count == AuditTokenExtraction.expectedByteCount)

        let gatekeeper = XPCAuditTokenGatekeeper(
            teamID: teamID,
            identifier: identifier,
            inspector: SecGuestCodeInspector()
        )
        let decision = gatekeeper.evaluate(auditToken: token, pid: getpid())
        #expect(!decision.accepted)
    }

    @Test("daemon admission logs rejected unauthorized callers")
    func daemonLogsRejectedCallers() {
        let audit = token(8)
        let inspector = StubGuestInspector(identities: [:])
        let daemon = EnforcementDaemon(
            gatekeeper: XPCAuditTokenGatekeeper(
                teamID: teamID,
                identifier: identifier,
                inspector: inspector
            )
        )
        let admitted = daemon.admitIncomingConnection(auditToken: audit, pid: 123)
        #expect(!admitted)
        let events = daemon.auditLog.snapshot()
        #expect(events.count == 1)
        #expect(events[0].accepted == false)
        #expect(events[0].pid == 123)
    }

    @Test("XPC client pins the helper Mach service and daemon requirement")
    func clientPinsDaemonRequirement() {
        let client = XPCEnforcementClient(teamID: teamID)
        #expect(client.machServiceName == ZoidLockInIdentity.enforcementMachServiceName)
        #expect(CodeRequirement.isTeamIDPinned(client.daemonCodeSigningRequirement))
        #expect(client.daemonCodeSigningRequirement.contains(ZoidLockInIdentity.daemonLabel))
        #expect(client.heartbeatIntervalSeconds == 1.0)
    }
}

private struct StubGuestInspector: GuestCodeInspecting {
    var identities: [Data: InspectedCodeIdentity]
    var requirementResults: [Data: Bool] = [:]

    func identity(forAuditToken data: Data) throws -> InspectedCodeIdentity {
        guard let identity = identities[data] else {
            throw XPCAuthenticationError.guestCodeUnavailable
        }
        return identity
    }

    func satisfiesRequirement(auditToken: Data, requirement: String) throws -> Bool {
        if let override = requirementResults[auditToken] {
            return override
        }
        let identity = try identity(forAuditToken: auditToken)
        return identity.isSignatureValid
            && CodeRequirement.isTeamIDPinned(requirement)
            && requirement.contains(identity.teamIdentifier)
            && requirement.contains("identifier \"\(identity.signingIdentifier)\"")
    }
}
