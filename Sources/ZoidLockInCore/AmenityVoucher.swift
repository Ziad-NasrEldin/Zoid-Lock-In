import CryptoKit
import Foundation

/// Claims bound into an amenity pass voucher. The privileged daemon verifies
/// these before granting a kind-scoped pass; it never opens the user-space ledger.
public struct AmenityPassClaims: Sendable, Equatable, Codable {
    public var kind: PassKind
    public var durationSeconds: Int
    public var nonce: String
    public var transactionID: UUID
    public var teamID: String

    public init(
        kind: PassKind,
        durationSeconds: Int,
        nonce: String,
        transactionID: UUID,
        teamID: String
    ) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.nonce = nonce
        self.transactionID = transactionID
        self.teamID = teamID
    }
}

public enum AmenityVoucherError: Error, Equatable, Sendable {
    case malformedPayload
    case invalidSignature
    case teamMismatch
    case kindNotRedeemable
    case durationMismatch
    case nonceMismatch
}

extension AmenityVoucherError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedPayload:
            return "Amenity voucher payload is malformed"
        case .invalidSignature:
            return "Amenity voucher signature is invalid"
        case .teamMismatch:
            return "Amenity voucher Team ID does not match this installation"
        case .kindNotRedeemable:
            return "This amenity kind cannot be redeemed as a daemon pass"
        case .durationMismatch:
            return "Amenity voucher duration does not match the catalog"
        case .nonceMismatch:
            return "Amenity voucher nonce does not match the redemption request"
        }
    }
}

/// HMAC-SHA256 key material derived from Team ID. User-space issuer and the
/// daemon verifier must use the same Team ID so a debit can be proven without
/// giving the helper SQLite access.
public enum AmenityVoucherSecrets: Sendable {
    public static let context = "com.mavoid.zoidlockin.amenity-voucher.v1"

    public static func hmacKey(teamID: String) -> SymmetricKey {
        let material = Data("\(context)|\(teamID)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }
}

/// User-space issuer. Called inside the ledger `BEGIN IMMEDIATE` debit so the
/// voucher is bound to the posted `WalletTransaction` id.
public struct AmenityVoucherIssuer: Sendable {
    private let hmacKey: SymmetricKey
    public let teamID: String

    public init(teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()) {
        self.teamID = teamID
        self.hmacKey = AmenityVoucherSecrets.hmacKey(teamID: teamID)
    }

    public func issue(
        kind: PassKind,
        durationSeconds: Int,
        nonce: String,
        transactionID: UUID
    ) -> AmenityPassVoucher {
        let claims = AmenityPassClaims(
            kind: kind,
            durationSeconds: durationSeconds,
            nonce: nonce,
            transactionID: transactionID,
            teamID: teamID
        )
        let payload = Self.encode(claims)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: hmacKey))
        return AmenityPassVoucher(payload: payload, signature: signature)
    }

    static func encode(_ claims: AmenityPassClaims) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(claims)) ?? Data()
    }
}

/// Privileged-side verifier. Rejects unsigned, tampered, emergency, and
/// off-catalog duration tickets before the daemon installs a pass.
public struct AmenityVoucherVerifier: Sendable {
    private let hmacKey: SymmetricKey
    public let teamID: String

    public init(teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()) {
        self.teamID = teamID
        self.hmacKey = AmenityVoucherSecrets.hmacKey(teamID: teamID)
    }

    public func verify(_ voucher: AmenityPassVoucher) throws -> AmenityPassClaims {
        guard !voucher.payload.isEmpty, !voucher.signature.isEmpty else {
            throw AmenityVoucherError.malformedPayload
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            voucher.signature,
            authenticating: voucher.payload,
            using: hmacKey
        )
        guard valid else {
            throw AmenityVoucherError.invalidSignature
        }

        let decoder = JSONDecoder()
        guard let claims = try? decoder.decode(AmenityPassClaims.self, from: voucher.payload) else {
            throw AmenityVoucherError.malformedPayload
        }
        guard claims.teamID == teamID else {
            throw AmenityVoucherError.teamMismatch
        }
        guard claims.kind.isAmenityPass else {
            throw AmenityVoucherError.kindNotRedeemable
        }
        guard claims.durationSeconds == claims.kind.catalogDurationSeconds else {
            throw AmenityVoucherError.durationMismatch
        }
        return claims
    }
}

/// User-space debit plus the ticket the daemon must redeem. Bed, outing, and
/// rest have no daemon pass (`voucher == nil`).
public struct AmenityPurchase: Sendable, Equatable {
    public var kind: AmenityKind
    public var transaction: WalletTransaction
    public var cost: Double
    public var voucher: AmenityPassVoucher?
    public var durationSeconds: Int?

    public init(
        kind: AmenityKind,
        transaction: WalletTransaction,
        cost: Double,
        voucher: AmenityPassVoucher?,
        durationSeconds: Int?
    ) {
        self.kind = kind
        self.transaction = transaction
        self.cost = cost
        self.voucher = voucher
        self.durationSeconds = durationSeconds
    }
}

/// XPC/in-process seam used by `MarketplaceCoordinator`. Implemented by the
/// daemon and the authenticated NSXPC client.
public protocol AmenityPassRedeeming: Sendable {
    func redeemAmenityVoucher(_ voucher: AmenityPassVoucher) async throws
}
