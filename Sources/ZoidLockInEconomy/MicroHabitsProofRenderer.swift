import AppKit
import SwiftUI
import ZoidLockInCore

public enum MicroHabitsProofError: Error, Equatable, Sendable {
    case renderFailed
}

/// Renders `MicroHabitsPopoverView` to a high-resolution PNG without showing a window.
public enum MicroHabitsProofRenderer: Sendable {
    public static let canvasSize = CGSize(width: 440, height: 780)
    public static let defaultScale: CGFloat = 3

    public static let defaultProofURL = URL(
        fileURLWithPath: "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In/screenshots/micro_habits_proof.png"
    )

    @MainActor
    public static func renderPNG(
        snapshot: MicroHabitsSnapshot = .proof,
        to url: URL = defaultProofURL,
        scale: CGFloat = defaultScale
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = MicroHabitsPopoverView(snapshot: snapshot)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: canvasSize)
        hosting.layoutSubtreeIfNeeded()

        let pixelsWide = Int((canvasSize.width * scale).rounded())
        let pixelsHigh = Int((canvasSize.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw MicroHabitsProofError.renderFailed
        }
        bitmap.size = canvasSize
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MicroHabitsProofError.renderFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url)
    }
}
