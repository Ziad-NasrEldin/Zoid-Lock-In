import CryptoKit
import Foundation

public enum TOTPError: Error, Equatable, Sendable {
    case invalidSecret
    case invalidCode
}

/// RFC 6238 TOTP (HMAC-SHA1, 30s step, 6 digits) compatible with Google Authenticator.
public enum TOTPEngine: Sendable {
    public static let digits = 6
    public static let timeStep: TimeInterval = 30
    public static let secretByteCount = 20
    public static let allowedWindows = 1
    public static let issuer = "Zoid Lock In"

    public static func generateSecret() throws -> String {
        let bytes = try PasswordHasher.randomBytes(secretByteCount)
        return Base32.encode([UInt8](bytes))
    }

    public static func otpAuthURL(secret: String, account: String = "admin") -> String {
        let encodedIssuer = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        let encodedAccount = account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? account
        return "otpauth://totp/\(encodedIssuer):\(encodedAccount)?secret=\(secret)&issuer=\(encodedIssuer)&period=30&digits=6&algorithm=SHA1"
    }

    public static func code(
        secretBytes: Data,
        at date: Date,
        digits: Int = TOTPEngine.digits,
        timeStep: TimeInterval = TOTPEngine.timeStep
    ) -> String {
        let counter = UInt64(date.timeIntervalSince1970 / timeStep)
        return hotp(secret: secretBytes, counter: counter, digits: digits)
    }

    public static func code(
        base32Secret: String,
        at date: Date,
        digits: Int = TOTPEngine.digits
    ) throws -> String {
        let secret = try Base32.decode(base32Secret)
        return code(secretBytes: Data(secret), at: date, digits: digits)
    }

    public static func verify(
        code: String,
        secretBytes: Data,
        at date: Date,
        digits: Int = TOTPEngine.digits,
        timeStep: TimeInterval = TOTPEngine.timeStep,
        allowedWindows: Int = TOTPEngine.allowedWindows
    ) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == digits, trimmed.allSatisfy(\.isNumber) else {
            return false
        }
        let counter = Int64(date.timeIntervalSince1970 / timeStep)
        let window = max(0, allowedWindows)
        for offset in -window...window {
            let candidate = hotp(
                secret: secretBytes,
                counter: UInt64(bitPattern: counter + Int64(offset)),
                digits: digits
            )
            if PasswordHasher.timingSafeEqual(Array(candidate.utf8), Array(trimmed.utf8)) {
                return true
            }
        }
        return false
    }

    public static func verify(
        code: String,
        base32Secret: String,
        at date: Date,
        allowedWindows: Int = TOTPEngine.allowedWindows
    ) throws -> Bool {
        let secret = try Base32.decode(base32Secret)
        return verify(
            code: code,
            secretBytes: Data(secret),
            at: date,
            allowedWindows: allowedWindows
        )
    }

    public static func hotp(secret: Data, counter: UInt64, digits: Int) -> String {
        var bigEndian = counter.bigEndian
        let counterData = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: SymmetricKey(data: secret))
        let hash = Array(mac)
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary =
            (UInt32(hash[offset] & 0x7F) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        let modulus = Self.powerOfTen(digits)
        let otp = binary % modulus
        return String(format: "%0\(digits)d", otp)
    }

    private static func powerOfTen(_ digits: Int) -> UInt32 {
        var value: UInt32 = 1
        for _ in 0..<digits {
            value *= 10
        }
        return value
    }
}

/// RFC 4648 Base32 (no padding required). Google Authenticator alphabet.
public enum Base32: Sendable {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                output.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            output.append(alphabet[index])
        }
        return output
    }

    public static func decode(_ string: String) throws -> [UInt8] {
        let cleaned = string
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
            .filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { throw TOTPError.invalidSecret }

        var lookup = [Character: UInt8]()
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        var buffer: UInt32 = 0
        var bitsLeft = 0
        var output: [UInt8] = []
        for character in cleaned {
            guard let value = lookup[character] else {
                throw TOTPError.invalidSecret
            }
            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }
        return output
    }
}
