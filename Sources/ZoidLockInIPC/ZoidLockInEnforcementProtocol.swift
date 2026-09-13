import Foundation
import ZoidLockInCore

/// Slice 2 XPC seam. The LaunchDaemon implements this; the filter sysex does not.
///
/// NSXPC mapping pins Team ID via `ZoidLockInIdentity.xpcClientRequirement(teamID:)`.
/// `MachServices` is advertised because `audit_token_t` validation ships with this slice.
///
/// Amenity `openPass` without a voucher still fails closed. Slice 4 redeems an
/// HMAC voucher over authenticated XPC. The filter must not be admitted to this
/// protocol; it reads `FilterEnforcementStatusReading` only.
public protocol ZoidLockInEnforcementServicing: Sendable, AmenityPassRedeeming {
    func applyPolicy(_ snapshot: EnforcementPolicySnapshot) async throws
    func openPass(kind: PassKind, durationSeconds: Int, nonce: String) async throws
    func revokePass(kind: PassKind) async throws
    func queryStatus() async throws -> EnforcementStatus
    func engageEmergencySafetyValve() async throws
    func heartbeat() async throws
    func queryUnleviedEmergencyIncidents() async throws -> [EmergencyIncidentRecord]
    func markEmergencyIncidentLevied(uuid: UUID) async throws
}
