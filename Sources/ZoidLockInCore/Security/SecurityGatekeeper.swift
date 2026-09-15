import Foundation

public enum SecurityGatekeeperError: Error, Equatable, Sendable {
    case passwordTooShort(minimum: Int)
    case passwordMismatch
    case passwordConfirmationMismatch
    case totpMismatch
    case notEnrolled
    case alreadyEnrolled
    case notUnlocked
}

extension SecurityGatekeeperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordTooShort(let minimum):
            return "Password must be at least \(minimum) characters."
        case .passwordMismatch:
            return "Password does not match."
        case .passwordConfirmationMismatch:
            return "Password confirmation does not match."
        case .totpMismatch:
            return "Authenticator code is invalid."
        case .notEnrolled:
            return "Admin credentials have not been enrolled."
        case .alreadyEnrolled:
            return "Admin credentials are already enrolled."
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

public struct AdminAuditRecord: Sendable, Equatable {
    public var kind: AdminAlertKind
    public var timestamp: Date
    public var recipient: String
    public var emailDispatched: Bool
    public var errorDescription: String?

    public init(
        kind: AdminAlertKind,
        timestamp: Date,
        recipient: String,
        emailDispatched: Bool,
        errorDescription: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.recipient = recipient
        self.emailDispatched = emailDispatched
        self.errorDescription = errorDescription
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
    public var mailDispatchFailed: Bool
    public var lastAuditEmailDispatched: Bool?

    public init(
        isEnrolled: Bool,
        isUnlocked: Bool,
        alertRecipient: String,
        unlockError: String? = nil,
        lastAlertKind: AdminAlertKind? = nil,
        mailDispatchFailed: Bool = false,
        lastAuditEmailDispatched: Bool? = nil
    ) {
        self.isEnrolled = isEnrolled
        self.isUnlocked = isUnlocked
        self.alertRecipient = alertRecipient
        self.unlockError = unlockError
        self.lastAlertKind = lastAlertKind
        self.mailDispatchFailed = mailDispatchFailed
        self.lastAuditEmailDispatched = lastAuditEmailDispatched
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

    public static let unenrolledProof = SecuritySettingsSnapshot(
        isEnrolled: false,
        isUnlocked: false,
        alertRecipient: "founder@mavoid.com"
    )
}

/// 12+ character password + RFC 6238 TOTP gate. Credentials live in Keychain.
/// Production must inject a real `KeychainDataStoring` — there is no in-memory default.
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
    private var replay = TOTPReplayWindow()
    private var auditEvents: [AdminAuditRecord] = []
    private var enrolledCached: Bool?
    private var cachedAlertRecipient: String?

    public init(
        keychain: any KeychainDataStoring,
        mail: any AdminAlertDispatching = NoOpAdminAlertDispatcher(),
        wallClock: any WallClockProviding = SystemWallClock(),
        service: String = ZoidLockInKeychain.securityService
    ) {
        self.keychain = keychain
        self.mail = mail
        self.wallClock = wallClock
        self.service = service
        if let stored = keychain.data(service: service, account: ZoidLockInKeychain.totpLastWindowAccount),
           let text = String(data: stored, encoding: .utf8),
           let value = UInt64(text) {
            replay.lastUsedTOTPWindow = value
        }
    }

    public var isUnlocked: Bool {
        withMutex { unlocked }
    }

    public var isEnrolled: Bool {
        withMutex {
            if let cached = enrolledCached {
                return cached
            }
            let enrolled = storedPasswordHash() != nil && storedTOTPSecret() != nil
            enrolledCached = enrolled
            return enrolled
        }
    }

    public var lastUsedTOTPWindow: UInt64? {
        withMutex { replay.lastUsedTOTPWindow }
    }

    public var alertRecipient: String {
        withMutex {
            if let cached = cachedAlertRecipient {
                return cached
            }
            if let data = keychain.data(service: service, account: ZoidLockInKeychain.alertRecipientAccount),
               let email = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !email.isEmpty {
                cachedAlertRecipient = email
                return email
            }
            cachedAlertRecipient = Self.defaultRecipient
            return Self.defaultRecipient
        }
    }

    public func snapshot() -> SecuritySettingsSnapshot {
        withMutex {
            let enrolled: Bool
            if let cached = enrolledCached {
                enrolled = cached
            } else {
                let check = storedPasswordHash() != nil && storedTOTPSecret() != nil
                enrolledCached = check
                enrolled = check
            }
            let recipient: String
            if let cached = cachedAlertRecipient {
                recipient = cached
            } else {
                if let data = keychain.data(service: service, account: ZoidLockInKeychain.alertRecipientAccount),
                   let email = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !email.isEmpty {
                    cachedAlertRecipient = email
                    recipient = email
                } else {
                    cachedAlertRecipient = Self.defaultRecipient
                    recipient = Self.defaultRecipient
                }
            }
            let failed = auditEvents.last.map { !$0.emailDispatched } ?? false
            return SecuritySettingsSnapshot(
                isEnrolled: enrolled,
                isUnlocked: unlocked,
                alertRecipient: recipient,
                unlockError: lastError,
                lastAlertKind: lastAlertKind,
                mailDispatchFailed: failed,
                lastAuditEmailDispatched: auditEvents.last?.emailDispatched
            )
        }
    }

    public func auditLog() -> [AdminAuditRecord] {
        withMutex { auditEvents }
    }

    @discardableResult
    public func enroll(
        password: String,
        passwordConfirmation: String? = nil,
        totpSecret: String? = nil,
        totpCode: String? = nil,
        recipient: String = SecurityGatekeeper.defaultRecipient
    ) throws -> SecurityEnrollment {
        if isEnrolled {
            rememberError(SecurityGatekeeperError.alreadyEnrolled.localizedDescription)
            throw SecurityGatekeeperError.alreadyEnrolled
        }
        if let passwordConfirmation, password != passwordConfirmation {
            rememberError(SecurityGatekeeperError.passwordConfirmationMismatch.localizedDescription)
            throw SecurityGatekeeperError.passwordConfirmationMismatch
        }
        do {
            try PasswordHasher.validateLength(password)
        } catch {
            rememberError(SecurityGatekeeperError.passwordTooShort(minimum: Self.minimumPasswordLength).localizedDescription)
            throw SecurityGatekeeperError.passwordTooShort(minimum: Self.minimumPasswordLength)
        }
        let secret = try totpSecret.map { try normalizeSecret($0) } ?? TOTPEngine.generateSecret()
        let now = wallClock.now()
        var enrollmentWindow: UInt64?
        if let totpCode {
            do {
                guard let window = try TOTPEngine.matchingCounter(
                    code: totpCode,
                    base32Secret: secret,
                    at: now
                ) else {
                    rememberError(SecurityGatekeeperError.totpMismatch.localizedDescription)
                    throw SecurityGatekeeperError.totpMismatch
                }
                enrollmentWindow = window
            } catch let error as SecurityGatekeeperError {
                throw error
            } catch {
                rememberError(SecurityGatekeeperError.totpMismatch.localizedDescription)
                throw SecurityGatekeeperError.totpMismatch
            }
        }
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
        if let enrollmentWindow {
            let accepted = withMutex { replay.consume(enrollmentWindow) }
            if accepted {
                persistReplayWindow(enrollmentWindow)
                markUnlocked(alertKind: .settingsUnlocked)
                let event = AdminAlertEvent(
                    kind: .settingsUnlocked,
                    timestamp: now,
                    recipient: recipient,
                    detail: "2FA enrollment completed"
                )
                Task { [weak self] in
                    await self?.dispatchAlertRecordingFailure(event)
                }
            }
        }
        withMutex {
            lastError = nil
            enrolledCached = true
            cachedAlertRecipient = recipient
        }
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

    /// Production always uses `wallClock.now()`. Tests inject `ManualWallClock`.
    public func verifyTOTP(_ code: String) -> Bool {
        guard let secret = storedTOTPSecret() else { return false }
        return (try? TOTPEngine.verify(code: code, base32Secret: secret, at: wallClock.now())) ?? false
    }

    @discardableResult
    public func unlock(password: String, totp: String) async throws -> SecuritySession {
        let moment = wallClock.now()
        guard isEnrolled else {
            rememberError(SecurityGatekeeperError.notEnrolled.localizedDescription)
            throw SecurityGatekeeperError.notEnrolled
        }
        guard verifyPassword(password) else {
            rememberError(SecurityGatekeeperError.passwordMismatch.localizedDescription)
            throw SecurityGatekeeperError.passwordMismatch
        }
        let window: UInt64
        do {
            window = try consumeTOTPWindow(totp, at: moment)
        } catch {
            rememberError(SecurityGatekeeperError.totpMismatch.localizedDescription)
            throw SecurityGatekeeperError.totpMismatch
        }

        markUnlocked(alertKind: .settingsUnlocked)
        persistReplayWindow(window)

        let recipient = alertRecipient
        let event = AdminAlertEvent(
            kind: .settingsUnlocked,
            timestamp: moment,
            recipient: recipient,
            detail: "2FA settings unlocked"
        )
        await dispatchAlertRecordingFailure(event)
        return SecuritySession(unlockedAt: moment, recipient: recipient)
    }

    public func noteConfigurationMutation(detail: String = "Administrative configuration mutated") {
        guard isUnlocked else { return }
        let event = AdminAlertEvent(
            kind: .configurationMutated,
            timestamp: wallClock.now(),
            recipient: alertRecipient,
            detail: detail
        )
        withMutex { lastAlertKind = .configurationMutated }
        Task { [weak self] in
            await self?.dispatchAlertRecordingFailure(event)
        }
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

    private func consumeTOTPWindow(_ code: String, at moment: Date) throws -> UInt64 {
        guard let secret = storedTOTPSecret() else {
            throw SecurityGatekeeperError.notEnrolled
        }
        guard let window = try TOTPEngine.matchingCounter(
            code: code,
            base32Secret: secret,
            at: moment
        ) else {
            throw SecurityGatekeeperError.totpMismatch
        }
        let accepted = withMutex { replay.consume(window) }
        guard accepted else {
            throw SecurityGatekeeperError.totpMismatch
        }
        return window
    }

    private func persistReplayWindow(_ window: UInt64) {
        try? keychain.setData(
            Data(String(window).utf8),
            service: service,
            account: ZoidLockInKeychain.totpLastWindowAccount
        )
    }

    private func dispatchAlertRecordingFailure(_ event: AdminAlertEvent) async {
        do {
            try await mail.dispatchAdminAlert(event)
            recordAudit(
                AdminAuditRecord(
                    kind: event.kind,
                    timestamp: event.timestamp,
                    recipient: event.recipient,
                    emailDispatched: true
                )
            )
        } catch {
            recordAudit(
                AdminAuditRecord(
                    kind: event.kind,
                    timestamp: event.timestamp,
                    recipient: event.recipient,
                    emailDispatched: false,
                    errorDescription: error.localizedDescription
                )
            )
        }
    }

    private func recordAudit(_ record: AdminAuditRecord) {
        withMutex {
            auditEvents.append(record)
            if !record.emailDispatched, lastError == nil {
                lastError = record.errorDescription
            }
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
