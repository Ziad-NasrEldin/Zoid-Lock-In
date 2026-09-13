import Foundation

/// Marketplace items whose prices Slice 3 must enforce for curfew and Friday rest.
public enum AmenityKind: String, Sendable, Equatable, Codable, CaseIterable, Hashable {
    case bed
    case food
    case phone
    case streaming
    case gaming
    case outing
    case rest

    public var displayName: String {
        switch self {
        case .bed: return "Bed Comfort"
        case .food: return "Food Pass"
        case .phone: return "Phone Pass"
        case .streaming: return "Streaming Pass"
        case .gaming: return "Gaming Pass"
        case .outing: return "Social Outings"
        case .rest: return "Rest Break"
        }
    }

    public var subtitle: String {
        switch self {
        case .bed: return "Evening bedtime, self-enforced"
        case .food: return "Talabat, Uber Eats, Elmenus"
        case .phone: return "Messaging portals for 60 minutes"
        case .streaming: return "YouTube, Netflix, Twitch"
        case .gaming: return "Steam, Discord, and game processes"
        case .outing: return "Dinner or evening with friends"
        case .rest: return "Midday break away from screens"
        }
    }

    /// SUMI-E seal glyph for the catalog row.
    public var sealGlyph: String {
        switch self {
        case .bed: return "寝"
        case .food: return "食"
        case .phone: return "話"
        case .streaming: return "映"
        case .gaming: return "遊"
        case .outing: return "友"
        case .rest: return "休"
        }
    }

    /// Daemon pass this amenity redeems, if any.
    public var passKind: PassKind? {
        switch self {
        case .food: return .food
        case .phone: return .phone
        case .streaming: return .streaming
        case .gaming: return .gaming
        case .bed, .outing, .rest:
            return nil
        }
    }
}

public struct AmenityCatalog: Sendable, Equatable {
    public static let standard = AmenityCatalog()

    public init() {}

    public func standardCost(of kind: AmenityKind) -> Double {
        switch kind {
        case .bed: return 3.0
        case .food: return 2.5
        case .phone: return 1.5
        case .streaming: return 1.5
        case .gaming: return 1.5
        case .outing: return 5.0
        case .rest: return 0.5
        }
    }

    /// Bed, food delivery, phone time, and rest breaks are free on Friday.
    public func isBasicComfort(_ kind: AmenityKind) -> Bool {
        switch kind {
        case .bed, .food, .phone, .rest:
            return true
        case .streaming, .gaming, .outing:
            return false
        }
    }

    public func isBlockedByCurfew(_ kind: AmenityKind) -> Bool {
        switch kind {
        case .food, .phone, .streaming, .gaming, .outing:
            return true
        case .bed, .rest:
            return false
        }
    }

    public func cost(of kind: AmenityKind, fridayRestMode: Bool) -> Double {
        if fridayRestMode && isBasicComfort(kind) {
            return 0
        }
        return standardCost(of: kind)
    }

    /// Seconds of unlocked time, or nil for non-timed amenities (bed, outing).
    public func durationSeconds(of kind: AmenityKind) -> Int? {
        switch kind {
        case .food, .gaming, .rest:
            return 30 * 60
        case .phone, .streaming:
            return 60 * 60
        case .bed, .outing:
            return nil
        }
    }

    public func durationCaption(of kind: AmenityKind) -> String {
        guard let seconds = durationSeconds(of: kind) else {
            return "Day"
        }
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}
