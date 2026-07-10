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
#if os(macOS)
    static var appBackground: Color { themedColor { $0.background } }
    static var sidebarBackground: Color {
        themedColor { palette in
            palette.mix(palette.background, palette.foreground, amount: 0.035)
                .withAlphaComponent(ThemePreferences.translucentSidebar ? 0.82 : 1)
        }
    }
    static var surface: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.025) }
    }
    static var surfaceSubtle: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.045) }
    }
    static var rowHover: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.07 * $0.contrastScale) }
    }
    static var rowSelected: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.105 * $0.contrastScale) }
    }
    static var border: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.14 * $0.contrastScale) }
    }
    static var divider: Color {
        themedColor { $0.mix($0.background, $0.foreground, amount: 0.10 * $0.contrastScale) }
    }
    static var mutedText: Color {
        themedColor { $0.mix($0.foreground, $0.background, amount: 0.42 / $0.contrastScale) }
    }
    static var faintText: Color {
        themedColor { $0.mix($0.foreground, $0.background, amount: 0.58 / $0.contrastScale) }
    }
    static var primaryText: Color { themedColor { $0.foreground } }
    static var accent: Color { themedColor { $0.accent } }

    private static func themedColor(_ resolve: @escaping (ResolvedThemePalette) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolve(ThemePreferences.palette(isDark: isDark))
        })
    }
#else
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
    static let primaryText = adaptive(light: "1A1C1F", dark: "F5F5F5")
    static let accent = Color.accentColor
#endif

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

#if os(macOS)
struct ResolvedThemePalette {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    let contrast: Double

    var contrastScale: Double { 0.65 + (contrast / 100) * 0.7 }

    func mix(_ first: NSColor, _ second: NSColor, amount: Double) -> NSColor {
        first.blended(withFraction: min(max(amount, 0), 1), of: second) ?? first
    }
}

enum ThemePreferences {
    static let revisionKey = "customThemeRevision"
    static let translucentSidebarKey = "customThemeTranslucentSidebar"
    static let contrastKey = "customThemeContrast"
    static let bodyFontSizeKey = "customThemeBodyFontSize"
    static let codeFontSizeKey = "customThemeCodeFontSize"

    static let lightAccentKey = "customThemeLightAccent"
    static let lightBackgroundKey = "customThemeLightBackground"
    static let lightForegroundKey = "customThemeLightForeground"
    static let darkAccentKey = "customThemeDarkAccent"
    static let darkBackgroundKey = "customThemeDarkBackground"
    static let darkForegroundKey = "customThemeDarkForeground"

    static let lightAccentDefault = "339CFF"
    static let lightBackgroundDefault = "FBFAF7"
    static let lightForegroundDefault = "1A1C1F"
    static let darkAccentDefault = "5EA7FF"
    static let darkBackgroundDefault = "171717"
    static let darkForegroundDefault = "F5F5F5"

    static var translucentSidebar: Bool {
        UserDefaults.standard.object(forKey: translucentSidebarKey) as? Bool ?? true
    }

    static var contrast: Double {
        let stored = UserDefaults.standard.object(forKey: contrastKey) as? Double
        return stored ?? 50
    }

    static var bodyFontSize: Double {
        UserDefaults.standard.object(forKey: bodyFontSizeKey) as? Double ?? 14
    }

    static var codeFontSize: Double {
        UserDefaults.standard.object(forKey: codeFontSizeKey) as? Double ?? 12
    }

    static func palette(isDark: Bool) -> ResolvedThemePalette {
        let defaults = UserDefaults.standard
        let backgroundDefault = isDark ? darkBackgroundDefault : lightBackgroundDefault
        let foregroundDefault = isDark ? darkForegroundDefault : lightForegroundDefault
        let accentDefault = isDark ? darkAccentDefault : lightAccentDefault
        let background = validHex(defaults.string(forKey: isDark ? darkBackgroundKey : lightBackgroundKey),
                                  fallback: backgroundDefault)
        let foreground = validHex(defaults.string(forKey: isDark ? darkForegroundKey : lightForegroundKey),
                                  fallback: foregroundDefault)
        let accent = validHex(defaults.string(forKey: isDark ? darkAccentKey : lightAccentKey),
                              fallback: accentDefault)
        return ResolvedThemePalette(
            background: NSColor(hex: background),
            foreground: NSColor(hex: foreground),
            accent: NSColor(hex: accent),
            contrast: contrast
        )
    }

    private static func validHex(_ value: String?, fallback: String) -> String {
        guard let value, value.count == 6, UInt64(value, radix: 16) != nil else { return fallback }
        return value
    }

    static func reset() {
        let keys = [
            lightAccentKey, lightBackgroundKey, lightForegroundKey,
            darkAccentKey, darkBackgroundKey, darkForegroundKey,
            translucentSidebarKey, contrastKey, bodyFontSizeKey, codeFontSizeKey,
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        bumpRevision()
    }

    static func bumpRevision() {
        let current = UserDefaults.standard.integer(forKey: revisionKey)
        UserDefaults.standard.set(current + 1, forKey: revisionKey)
    }
}
#else
enum ThemePreferences {
    static var bodyFontSize: Double { 14 }
    static var codeFontSize: Double { 12 }
}
#endif

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

    var rgbHexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        return String(
            format: "%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}

extension Color {
    var rgbHexString: String {
        NSColor(self).rgbHexString
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
