import Foundation

public enum SecurityGatekeeperError: Error, Equatable, Sendable {
    case passwordTooShort(minimum: Int)
    case passwordMismatch
    case totpMismatch
    case notEnrolled
    case notUnlocked
}

extension SecurityGatekeeperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordTooShort(let minimum):
            return "Password must be at least \(minimum) characters."
        case .passwordMismatch:
            return "Password does not match."
        case .totpMismatch:
            return "Authenticator code is invalid."
        case .notEnrolled:
            return "Admin credentials have not been enrolled."
        case .notUnlocked:
            return "Settings are locked. Authenticate with password and TOTP."
        }
    }
}

public enum AdminAlertKind: String, Sendable, Equatable, Codable {
    case settingsUnlocked = "ADMIN_LOGIN"
    case configurationMutated = "CONFIG_MUTATION"
}

public struct AdminAlertEvent: Sendable, Equatable {
    public var kind: AdminAlertKind
    public var timestamp: Date
    public var recipient: String
    public var detail: String

    public init(
        kind: AdminAlertKind,
        timestamp: Date,
        recipient: String,
        detail: String = ""
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.recipient = recipient
        self.detail = detail
    }
}

public protocol AdminAlertDispatching: Sendable {
    func dispatchAdminAlert(_ event: AdminAlertEvent) async throws
}

public struct NoOpAdminAlertDispatcher: AdminAlertDispatching, Sendable {
    public init() {}

    public func dispatchAdminAlert(_ event: AdminAlertEvent) async throws {
        _ = event
    }
}

public struct SecurityEnrollment: Sendable, Equatable {
    public var totpSecretBase32: String
    public var otpAuthURL: String
}

public struct SecuritySession: Sendable, Equatable {
    public var unlockedAt: Date
    public var recipient: String
}

public struct SecuritySettingsSnapshot: Sendable, Equatable {
    public var isEnrolled: Bool
    public var isUnlocked: Bool
    public var alertRecipient: String
    public var unlockError: String?
    public var lastAlertKind: AdminAlertKind?

    public init(
        isEnrolled: Bool,
        isUnlocked: Bool,
        alertRecipient: String,
        unlockError: String? = nil,
        lastAlertKind: AdminAlertKind? = nil
    ) {
        self.isEnrolled = isEnrolled
        self.isUnlocked = isUnlocked
        self.alertRecipient = alertRecipient
        self.unlockError = unlockError
        self.lastAlertKind = lastAlertKind
    }

    public static let lockedProof = SecuritySettingsSnapshot(
        isEnrolled: true,
        isUnlocked: false,
        alertRecipient: "founder@mavoid.com"
    )

    public static let unlockedProof = SecuritySettingsSnapshot(
        isEnrolled: true,
        isUnlocked: true,
        alertRecipient: "founder@mavoid.com",
        lastAlertKind: .settingsUnlocked
    )
}

/// 12+ character password + RFC 6238 TOTP gate. Credentials live in Keychain.
public final class SecurityGatekeeper: @unchecked Sendable {
    public static let minimumPasswordLength = PasswordHasher.minimumLength
    public static let defaultRecipient = "founder@mavoid.com"

    public let keychain: any KeychainDataStoring
    public let mail: any AdminAlertDispatching
    public let wallClock: any WallClockProviding
    public let service: String

    private let mutex = NSLock()
    private var unlocked = false
    private var lastError: String?
    private var lastAlertKind: AdminAlertKind?

    public init(
        keychain: any KeychainDataStoring = InMemoryKeychainStore(),
        mail: any AdminAlertDispatching = NoOpAdminAlertDispatcher(),
        wallClock: any WallClockProviding = SystemWallClock(),
        service: String = ZoidLockInKeychain.securityService
    ) {
        self.keychain = keychain
        self.mail = mail
        self.wallClock = wallClock
        self.service = service
    }

    public var isUnlocked: Bool {
        withMutex { unlocked }
    }

    public var isEnrolled: Bool {
        storedPasswordHash() != nil && storedTOTPSecret() != nil
    }

    public var alertRecipient: String {
        if let data = keychain.data(service: service, account: ZoidLockInKeychain.alertRecipientAccount),
           let email = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        return Self.defaultRecipient
    }

    public func snapshot() -> SecuritySettingsSnapshot {
        withMutex {
            SecuritySettingsSnapshot(
                isEnrolled: storedPasswordHash() != nil && storedTOTPSecret() != nil,
                isUnlocked: unlocked,
                alertRecipient: alertRecipient,
                unlockError: lastError,
                lastAlertKind: lastAlertKind
            )
        }
    }

    @discardableResult
    public func enroll(
        password: String,
        totpSecret: String? = nil,
        recipient: String = SecurityGatekeeper.defaultRecipient
    ) throws -> SecurityEnrollment {
        do {
            try PasswordHasher.validateLength(password)
        } catch {
            throw SecurityGatekeeperError.passwordTooShort(minimum: Self.minimumPasswordLength)
        }
        let secret = try totpSecret.map { try normalizeSecret($0) } ?? TOTPEngine.generateSecret()
        let hash = try PasswordHasher.hash(password)
        try keychain.setData(
            Data(hash.utf8),
            service: service,
            account: ZoidLockInKeychain.passwordHashAccount
        )
        try keychain.setData(
            Data(secret.utf8),
            service: service,
            account: ZoidLockInKeychain.totpSecretAccount
        )
        try keychain.setData(
            Data(recipient.utf8),
            service: service,
            account: ZoidLockInKeychain.alertRecipientAccount
        )
        return SecurityEnrollment(
            totpSecretBase32: secret,
            otpAuthURL: TOTPEngine.otpAuthURL(secret: secret)
        )
    }

    public func verifyPassword(_ password: String) -> Bool {
        guard let stored = storedPasswordHash() else { return false }
        if password.count < Self.minimumPasswordLength { return false }
        return PasswordHasher.verify(password, against: stored)
    }

    public func verifyTOTP(_ code: String, at date: Date? = nil) -> Bool {
        guard let secret = storedTOTPSecret() else { return false }
        return (try? TOTPEngine.verify(code: code, base32Secret: secret, at: date ?? wallClock.now())) ?? false
    }

    @discardableResult
    public func unlock(password: String, totp: String, at date: Date? = nil) async throws -> SecuritySession {
        let moment = date ?? wallClock.now()
        guard isEnrolled else {
            rememberError(SecurityGatekeeperError.notEnrolled.localizedDescription)
            throw SecurityGatekeeperError.notEnrolled
        }
        guard verifyPassword(password) else {
            rememberError(SecurityGatekeeperError.passwordMismatch.localizedDescription)
            throw SecurityGatekeeperError.passwordMismatch
        }
        guard verifyTOTP(totp, at: moment) else {
            rememberError(SecurityGatekeeperError.totpMismatch.localizedDescription)
            throw SecurityGatekeeperError.totpMismatch
        }

        markUnlocked(alertKind: .settingsUnlocked)

        let recipient = alertRecipient
        let event = AdminAlertEvent(
            kind: .settingsUnlocked,
            timestamp: moment,
            recipient: recipient,
            detail: "2FA settings unlocked"
        )
        try? await mail.dispatchAdminAlert(event)
        return SecuritySession(unlockedAt: moment, recipient: recipient)
    }

    public func noteConfigurationMutation(detail: String = "Administrative configuration mutated") async {
        guard isUnlocked else { return }
        let event = AdminAlertEvent(
            kind: .configurationMutated,
            timestamp: wallClock.now(),
            recipient: alertRecipient,
            detail: detail
        )
        withMutex { lastAlertKind = .configurationMutated }
        try? await mail.dispatchAdminAlert(event)
    }

    public func lockSettings() {
        withMutex {
            unlocked = false
            lastError = nil
        }
    }

    public func requireUnlocked() throws {
        guard isUnlocked else {
            throw SecurityGatekeeperError.notUnlocked
        }
    }

    private func markUnlocked(alertKind: AdminAlertKind) {
        withMutex {
            unlocked = true
            lastError = nil
            lastAlertKind = alertKind
        }
    }

    private func withMutex<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    private func storedPasswordHash() -> String? {
        guard let data = keychain.data(service: service, account: ZoidLockInKeychain.passwordHashAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func storedTOTPSecret() -> String? {
        guard let data = keychain.data(service: service, account: ZoidLockInKeychain.totpSecretAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func normalizeSecret(_ secret: String) throws -> String {
        let decoded = try Base32.decode(secret)
        guard !decoded.isEmpty else { throw TOTPError.invalidSecret }
        return Base32.encode(decoded)
    }

    private func rememberError(_ message: String) {
        withMutex { lastError = message }
    }
}
