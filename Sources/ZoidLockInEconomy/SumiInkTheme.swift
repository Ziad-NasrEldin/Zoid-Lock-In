import AppKit
import SwiftUI

/// SUMI-E Ink tokens for the menu-bar companion: rice paper, sumi, vermilion seal.
public enum SumiInk: Sendable {
    public static let paper = Color(red: 0.965, green: 0.945, blue: 0.906)
    public static let paperSoft = Color(red: 0.984, green: 0.969, blue: 0.941)
    public static let ink = Color(red: 0.07, green: 0.06, blue: 0.05)
    public static let inkMuted = Color(red: 0.38, green: 0.34, blue: 0.29)
    public static let rule = Color(red: 0.55, green: 0.50, blue: 0.44).opacity(0.45)
    public static let seal = Color(red: 194 / 255, green: 58 / 255, blue: 46 / 255)
    public static let sealWash = Color(red: 245 / 255, green: 229 / 255, blue: 227 / 255)

    public static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    public static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    public static func caption(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}
