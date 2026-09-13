import Foundation

/// Privileged-side authorization failures. These are daemon policy, not UX.
public enum EnforcementControlError: Error, Equatable, Sendable {
    case passAlreadyActive
    case emergencyCooldownActive(remainingSeconds: TimeInterval)
    case amenityPassRequiresVoucher
    case invalidAmenityVoucher(String)
    case policyRejected(String)
    case replayNonceRejected
    case curfewActive
}

extension EnforcementControlError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passAlreadyActive:
            return "An enforcement pass is already active"
        case .emergencyCooldownActive(let remaining):
            return "Emergency safety valve is in cooldown (\(Int(remaining.rounded(.up)))s remaining)"
        case .amenityPassRequiresVoucher:
            return "Amenity passes require a Slice 4 cryptographic voucher"
        case .invalidAmenityVoucher(let reason):
            return "Amenity voucher rejected: \(reason)"
        case .policyRejected(let reason):
            return "Enforcement policy rejected: \(reason)"
        case .replayNonceRejected:
            return "Replay nonce rejected"
        case .curfewActive:
            return "Curfew is active (22:00–03:59). Entertainment and food passes are locked."
        }
    }
}
