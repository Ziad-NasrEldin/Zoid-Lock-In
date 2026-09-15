/// Socket-level content filter decision for an outbound flow.
public enum FilterVerdict: String, Sendable, Equatable {
    case allow
    case drop
    /// Calibration warning for a **verified** blacklisted hostname. Unverified
    /// identities on inspected ports stay `.drop`. The Network Extension maps
    /// this to allow after recording an infraction.
    case softInfraction = "soft_infraction"

    public var dropsPackets: Bool {
        self == .drop
    }
}
