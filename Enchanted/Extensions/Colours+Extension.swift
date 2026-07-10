//
//  Colours.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Palette
extension Color {
    static let labelCustom = Color("label")
}

// MARK: - Codex-inspired interface colors
enum CodexTheme {
    static let appBackground = adaptive(light: "FBFAF7", dark: "171717")
    static let sidebarBackground = adaptive(light: "F3F2EF", dark: "202020")
    static let surface = adaptive(light: "FFFFFF", dark: "242424")
    static let surfaceSubtle = adaptive(light: "F7F6F3", dark: "2A2A2A")
    static let rowHover = adaptive(light: "EDEBE6", dark: "303030")
    static let rowSelected = adaptive(light: "E7E4DC", dark: "383838")
    static let border = adaptive(light: "DEDAD1", dark: "3A3A3A")
    static let divider = adaptive(light: "E8E4DB", dark: "333333")
    static let mutedText = adaptive(light: "72706A", dark: "A6A39B")
    static let faintText = adaptive(light: "9C978C", dark: "77736C")

    static func adaptive(light: String, dark: String) -> Color {
#if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
#elseif os(iOS) || os(visionOS)
        return Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
#else
        return Color(hex: light)
#endif
    }
}

// MARK: - hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 0)
        }
        let red = CGFloat(r) / CGFloat(255)
        let green = CGFloat(g) / CGFloat(255)
        let blue = CGFloat(b) / CGFloat(255)
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
#elseif os(iOS) || os(visionOS)
private extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 0)
        }
        let red = CGFloat(r) / CGFloat(255)
        let green = CGFloat(g) / CGFloat(255)
        let blue = CGFloat(b) / CGFloat(255)
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
