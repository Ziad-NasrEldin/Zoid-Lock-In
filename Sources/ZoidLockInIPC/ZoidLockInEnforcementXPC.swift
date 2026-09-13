import Foundation

/// NSXPC wire protocol. Custom Swift structs travel as JSON `Data`.
@objc(ZoidLockInEnforcementXPC)
public protocol ZoidLockInEnforcementXPC: NSObjectProtocol {
    func applyPolicy(_ snapshotJSON: Data, withReply reply: @escaping (NSError?) -> Void)
    func openPassWithKind(
        _ kind: String,
        durationSeconds: Int,
        nonce: String,
        withReply reply: @escaping (NSError?) -> Void
    )
    func redeemAmenityVoucher(_ voucherJSON: Data, withReply reply: @escaping (NSError?) -> Void)
    func revokePassWithKind(_ kind: String, withReply reply: @escaping (NSError?) -> Void)
    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
    func engageEmergencySafetyValve(withReply reply: @escaping (NSError?) -> Void)
    func heartbeat(withReply reply: @escaping (NSError?) -> Void)
    func queryUnleviedEmergencyIncidents(withReply reply: @escaping (Data?, NSError?) -> Void)
    func markEmergencyIncidentLeviedWithUUID(_ uuid: String, withReply reply: @escaping (NSError?) -> Void)
}

public enum ZoidLockInXPCError {
    public static let domain = "com.mavoid.zoidlockin.xpc"

    public static func make(_ code: Int, message: String) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
