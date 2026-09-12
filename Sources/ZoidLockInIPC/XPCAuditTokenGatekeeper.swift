import Foundation
import Security
import ZoidLockInCore

public enum XPCAuthenticationError: Error, Equatable, Sendable {
    case missingAuditToken
    case guestCodeUnavailable
    case signatureInvalid
    case teamIdentifierMismatch(found: String, expected: String)
    case identifierMismatch(found: String, expected: String)
    case requirementStringUnsafe
    case unauthorized
}

public struct InspectedCodeIdentity: Sendable, Equatable {
    public var signingIdentifier: String
    public var teamIdentifier: String
    public var isSignatureValid: Bool

    public init(
        signingIdentifier: String,
        teamIdentifier: String,
        isSignatureValid: Bool
    ) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.isSignatureValid = isSignatureValid
    }
}

public struct XPCAdmissionDecision: Sendable, Equatable {
    public var accepted: Bool
    public var identity: InspectedCodeIdentity?
    public var rejection: XPCAuthenticationError?

    public static func accept(_ identity: InspectedCodeIdentity) -> XPCAdmissionDecision {
        XPCAdmissionDecision(accepted: true, identity: identity, rejection: nil)
    }

    public static func reject(
        _ reason: XPCAuthenticationError,
        identity: InspectedCodeIdentity? = nil
    ) -> XPCAdmissionDecision {
        XPCAdmissionDecision(accepted: false, identity: identity, rejection: reason)
    }
}

public struct XPCConnectionAuditEvent: Sendable, Equatable {
    public var accepted: Bool
    public var pid: pid_t
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    public var reason: String
    public var atSeconds: TimeInterval

    public init(
        accepted: Bool,
        pid: pid_t,
        signingIdentifier: String?,
        teamIdentifier: String?,
        reason: String,
        atSeconds: TimeInterval
    ) {
        self.accepted = accepted
        self.pid = pid
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.reason = reason
        self.atSeconds = atSeconds
    }
}

public protocol GuestCodeInspecting: Sendable {
    func identity(forAuditToken data: Data) throws -> InspectedCodeIdentity
    func satisfiesRequirement(auditToken: Data, requirement: String) throws -> Bool
}

/// Security.framework guest-code inspector keyed by `audit_token_t`, never by PID.
public struct SecGuestCodeInspector: GuestCodeInspecting {
    public init() {}

    public func identity(forAuditToken data: Data) throws -> InspectedCodeIdentity {
        let guest = try copyGuest(auditToken: data)
        let validSignature = SecCodeCheckValidity(guest, [], nil) == errSecSuccess

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(guest, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return InspectedCodeIdentity(
                signingIdentifier: "",
                teamIdentifier: "",
                isSignatureValid: validSignature
            )
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        let info = (infoStatus == errSecSuccess ? information as? [String: Any] : nil) ?? [:]
        let identifier = (info[kSecCodeInfoIdentifier as String] as? String) ?? ""
        let team = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""

        return InspectedCodeIdentity(
            signingIdentifier: identifier,
            teamIdentifier: team,
            isSignatureValid: validSignature
        )
    }

    public func satisfiesRequirement(auditToken: Data, requirement: String) throws -> Bool {
        let guest = try copyGuest(auditToken: auditToken)
        var secRequirement: SecRequirement?
        let createStatus = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &secRequirement
        )
        guard createStatus == errSecSuccess, let secRequirement else {
            throw XPCAuthenticationError.requirementStringUnsafe
        }
        return SecCodeCheckValidity(guest, [], secRequirement) == errSecSuccess
    }

    private func copyGuest(auditToken: Data) throws -> SecCode {
        guard auditToken.count == AuditTokenExtraction.expectedByteCount else {
            throw XPCAuthenticationError.missingAuditToken
        }

        var guest: SecCode?
        let attributes: [CFString: Any] = [kSecGuestAttributeAudit: auditToken]
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            [],
            &guest
        )
        guard status == errSecSuccess, let guest else {
            throw XPCAuthenticationError.guestCodeUnavailable
        }
        return guest
    }
}

/// Authenticates NSXPC clients from `audit_token_t` against a Team-ID-pinned requirement.
public struct XPCAuditTokenGatekeeper: Sendable {
    public var teamID: String
    public var identifier: String
    public var inspector: any GuestCodeInspecting

    public var requirementString: String {
        CodeRequirement(teamID: teamID, identifier: identifier).requirementString
    }

    public init(
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier(),
        identifier: String = ZoidLockInIdentity.applicationBundleIdentifier,
        inspector: any GuestCodeInspecting = SecGuestCodeInspector()
    ) {
        self.teamID = teamID
        self.identifier = identifier
        self.inspector = inspector
    }

    public func evaluate(auditToken: Data, pid: pid_t = 0) -> XPCAdmissionDecision {
        _ = pid
        guard auditToken.count == AuditTokenExtraction.expectedByteCount else {
            return .reject(.missingAuditToken)
        }
        guard CodeRequirement.sanitizedTeamIdentifier(teamID) != nil,
              CodeRequirement.sanitizedCodeIdentifier(identifier) != nil,
              CodeRequirement.isTeamIDPinned(requirementString) else {
            return .reject(.requirementStringUnsafe)
        }

        let identity: InspectedCodeIdentity
        do {
            identity = try inspector.identity(forAuditToken: auditToken)
        } catch let error as XPCAuthenticationError {
            return .reject(error)
        } catch {
            return .reject(.guestCodeUnavailable)
        }

        if !identity.isSignatureValid {
            return .reject(.signatureInvalid, identity: identity)
        }

        do {
            let satisfied = try inspector.satisfiesRequirement(
                auditToken: auditToken,
                requirement: requirementString
            )
            if !satisfied {
                return .reject(.unauthorized, identity: identity)
            }
        } catch let error as XPCAuthenticationError {
            return .reject(error, identity: identity)
        } catch {
            return .reject(.unauthorized, identity: identity)
        }

        if identity.teamIdentifier != teamID {
            return .reject(
                .teamIdentifierMismatch(found: identity.teamIdentifier, expected: teamID),
                identity: identity
            )
        }
        if identity.signingIdentifier != identifier {
            return .reject(
                .identifierMismatch(found: identity.signingIdentifier, expected: identifier),
                identity: identity
            )
        }

        return .accept(identity)
    }
}

public final class XPCConnectionAuditLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [XPCConnectionAuditEvent] = []

    public init() {}

    public func record(_ event: XPCConnectionAuditEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    public func snapshot() -> [XPCConnectionAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
