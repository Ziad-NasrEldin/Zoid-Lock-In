/// Socket-level content filter decision for an outbound flow.
public enum FilterVerdict: String, Sendable, Equatable {
    case allow
    case drop
    /// Calibration / soft-warning mode: the flow would drop in hard lockdown,
    /// but packets are not discarded. The Network Extension maps this to allow.
    case softInfraction = "soft_infraction"

    public var dropsPackets: Bool {
        self == .drop
    }
}
