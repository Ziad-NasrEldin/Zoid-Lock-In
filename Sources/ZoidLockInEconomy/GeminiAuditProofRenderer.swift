import AppKit
import SwiftUI
import ZoidLockInCore

public enum GeminiAuditProofError: Error, Equatable, Sendable {
    case renderFailed
}

/// Renders the Slice 7 Gemini audit / Pro arbitration meeting sheet to PNG.
public enum GeminiAuditProofRenderer: Sendable {
    public static let canvasSize = CGSize(width: 440, height: 860)
    public static let defaultScale: CGFloat = 3

    public static let defaultProofURL = URL(
        fileURLWithPath: "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In/screenshots/gemini_audit_proof.png"
    )

    @MainActor
    public static func renderPNG(
        snapshot: OfflineMeetingSnapshot = .geminiAuditProof,
        to url: URL = defaultProofURL,
        scale: CGFloat = defaultScale
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = OfflineMeetingPopoverView(
            snapshot: snapshot,
            onAppeal: { _ in }
        )
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
            throw GeminiAuditProofError.renderFailed
        }
        bitmap.size = canvasSize
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GeminiAuditProofError.renderFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url)
    }
}
