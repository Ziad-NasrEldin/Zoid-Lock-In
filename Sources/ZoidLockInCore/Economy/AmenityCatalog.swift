import Foundation

/// Marketplace items whose prices Slice 3 must enforce for curfew and Friday rest.
public enum AmenityKind: String, Sendable, Equatable, Codable, CaseIterable {
    case bed
    case food
    case phone
    case streaming
    case gaming
    case outing
    case rest
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
}
