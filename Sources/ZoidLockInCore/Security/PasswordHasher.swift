import CryptoKit
import Foundation
import Security

public enum PasswordHashingError: Error, Equatable, Sendable {
    case tooShort(minimum: Int)
    case tooWeak(missing: [String])
    case malformedStoredHash
    case randomGenerationFailed
}

/// PBKDF2-HMAC-SHA256 password hashing. Stored as
/// `pbkdf2-sha256$iterations$saltB64$hashB64`.
public enum PasswordHasher: Sendable {
    public static let minimumLength = 12
    public static let defaultIterations = 100_000
    public static let saltLength = 16
    public static let derivedKeyLength = 32

    public static func validateLength(_ password: String) throws {
        if password.count < minimumLength {
            throw PasswordHashingError.tooShort(minimum: minimumLength)
        }
    }

    /// Evaluates password complexity according to PRODUCT.md §6.1:
    /// minimum 12 chars with uppercase, lowercase, numbers, and symbols.
    public static func validateComplexity(_ password: String) -> (isValid: Bool, missing: [String]) {
        var missing: [String] = []
        if password.count < minimumLength {
            missing.append("At least \(minimumLength) characters")
        }
        if !password.contains(where: { $0.isUppercase }) {
            missing.append("Uppercase letter")
        }
        if !password.contains(where: { $0.isLowercase }) {
            missing.append("Lowercase letter")
        }
        if !password.contains(where: { $0.isNumber }) {
            missing.append("Number")
        }
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)
        if password.unicodeScalars.first(where: { symbols.contains($0) }) == nil {
            missing.append("Symbol")
        }
        return (missing.isEmpty, missing)
    }

    public static func hash(
        _ password: String,
        iterations: Int = defaultIterations
    ) throws -> String {
        try validateLength(password)
        let complexity = validateComplexity(password)
        if !complexity.isValid {
            throw PasswordHashingError.tooWeak(missing: complexity.missing)
        }
        let salt = try randomBytes(saltLength)
        let key = derive(
            password: Data(password.utf8),
            salt: salt,
            iterations: iterations,
            derivedKeyLength: derivedKeyLength
        )
        return "pbkdf2-sha256$\(iterations)$\(salt.base64EncodedString())$\(Data(key).base64EncodedString())"
    }

    public static func verify(_ password: String, against stored: String) -> Bool {
        guard let parsed = parse(stored) else { return false }
        let computed = derive(
            password: Data(password.utf8),
            salt: parsed.salt,
            iterations: parsed.iterations,
            derivedKeyLength: parsed.hash.count
        )
        return timingSafeEqual(computed, [UInt8](parsed.hash))
    }

    public static func parse(_ stored: String) -> (iterations: Int, salt: Data, hash: Data)? {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "pbkdf2-sha256", let iterations = Int(parts[1]) else {
            return nil
        }
        guard let salt = Data(base64Encoded: parts[2]), let hash = Data(base64Encoded: parts[3]) else {
            return nil
        }
        return (iterations, salt, hash)
    }

    public static func derive(
        password: Data,
        salt: Data,
        iterations: Int,
        derivedKeyLength: Int
    ) -> [UInt8] {
        let passwordKey = SymmetricKey(data: password)
        var output: [UInt8] = []
        output.reserveCapacity(derivedKeyLength)
        var block: UInt32 = 1
        while output.count < derivedKeyLength {
            var saltBlock = Data(salt)
            var bigEndian = block.bigEndian
            withUnsafeBytes(of: &bigEndian) { saltBlock.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: saltBlock, using: passwordKey))
            var accumulated = [UInt8](u)
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                    for index in 0..<accumulated.count {
                        accumulated[index] ^= u[index]
                    }
                }
            }
            output.append(contentsOf: accumulated)
            block += 1
        }
        return Array(output.prefix(derivedKeyLength))
    }

    public static func timingSafeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    public static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw PasswordHashingError.randomGenerationFailed
        }
        return data
    }
}
