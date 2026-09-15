import AppKit
import SwiftUI
import ZoidLockInCore

public enum DesktopDashboardProofError: Error, Equatable, Sendable {
    case renderFailed
}

/// Renders `CommandDashboardView` to a high-resolution PNG without showing a window.
public enum DesktopDashboardProofRenderer: Sendable {
    public static let canvasSize = CGSize(width: 1200, height: 800)
    public static let defaultScale: CGFloat = 2

    public static let defaultProofURL = URL(
        fileURLWithPath: "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In/screenshots/desktop_dashboard_proof.png"
    )

    public static let calibrationProofURL = URL(
        fileURLWithPath: "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In/screenshots/calibration_mode_proof.png"
    )

    @MainActor
    public static func renderPNG(
        snapshot: CommandDashboardSnapshot = .proof,
        to url: URL = defaultProofURL,
        scale: CGFloat = defaultScale
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = CommandDashboardView(snapshot: snapshot)
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
            throw DesktopDashboardProofError.renderFailed
        }
        bitmap.size = canvasSize
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DesktopDashboardProofError.renderFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url)
    }

    @MainActor
    public static func renderProofSet(
        scale: CGFloat = defaultScale
    ) throws {
        try renderPNG(snapshot: .proof, to: defaultProofURL, scale: scale)
        try renderPNG(snapshot: .proof, to: calibrationProofURL, scale: scale)
    }
}
