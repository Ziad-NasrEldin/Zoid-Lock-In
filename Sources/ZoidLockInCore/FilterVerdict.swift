/// Socket-level content filter decision for an outbound flow.
public enum FilterVerdict: String, Sendable, Equatable {
    case allow
    case drop
}
