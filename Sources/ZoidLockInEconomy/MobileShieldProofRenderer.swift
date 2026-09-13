import AppKit
import SwiftUI
import ZoidLockInCore

public enum MobileShieldProofError: Error, Equatable, Sendable {
    case renderFailed
}

/// Renders the marketplace popover with the Mobile Shield banner to PNG.
public enum MobileShieldProofRenderer: Sendable {
    public static let canvasSize = MarketplaceProofRenderer.canvasSize
    public static let defaultScale: CGFloat = 3

    public static let defaultProofURL = URL(
        fileURLWithPath: "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In/screenshots/mobile_shield_proof.png"
    )

    @MainActor
    public static func renderPNG(
        snapshot: MarketplaceSnapshot = .mobileShieldProof,
        to url: URL = defaultProofURL,
        scale: CGFloat = defaultScale
    ) throws {
        try MarketplaceProofRenderer.renderPNG(snapshot: snapshot, to: url, scale: scale)
    }
}
