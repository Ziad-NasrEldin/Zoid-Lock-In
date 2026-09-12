import Darwin
import Foundation

/// Helpers for `audit_token_t` used by `SecCodeCopyGuestWithAttributes`.
public enum AuditTokenExtraction: Sendable {
    public static var expectedByteCount: Int {
        MemoryLayout<audit_token_t>.size
    }

    public static func data(from token: audit_token_t) -> Data {
        var token = token
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// `NSXPCConnection.auditToken` is not imported into Swift; read it via KVC.
    public static func data(fromConnection connection: NSXPCConnection) -> Data? {
        guard let raw = connection.value(forKey: "auditToken") else {
            return nil
        }
        if let data = raw as? Data, data.count == expectedByteCount {
            return data
        }
        if let value = raw as? NSValue {
            var token = audit_token_t()
            value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
            return data(from: token)
        }
        return nil
    }

    public static func currentProcess() throws -> Data {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &token) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_AUDIT_TOKEN),
                    intPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw XPCAuthenticationError.missingAuditToken
        }
        return data(from: token)
    }
}
