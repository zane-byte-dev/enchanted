//
//  MarkdownColours.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 13/05/2024.
//

import SwiftUI
import MarkdownUI

struct MarkdownColours {
    static let text = Color(
        light: Color(rgba: 0x0606_06ff), dark: Color(rgba: 0xfbfb_fcff)
    )
    static let secondaryText = Color(
        light: Color(rgba: 0x6b6e_7bff), dark: Color(rgba: 0x9294_a0ff)
    )
    static let tertiaryText = Color(
        light: Color(rgba: 0x6b6e_7bff), dark: Color(rgba: 0x6d70_7dff)
    )
    static let background = Color(
        light: .white, dark: Color(rgba: 0x1819_1dff)
    )
    static let secondaryBackground = Color(
        light: Color(rgba: 0xf7f7_f9ff), dark: Color(rgba: 0x2526_2aff)
    )
    static let link = Color(
        light: Color(rgba: 0x2c65_cfff), dark: Color(rgba: 0x4c8e_f8ff)
    )
    static let border = Color(
        light: Color(rgba: 0xe4e4_e8ff), dark: Color(rgba: 0x4244_4eff)
    )
    static let divider = Color(
        light: Color(rgba: 0xd0d0_d3ff), dark: Color(rgba: 0x3334_38ff)
    )
    static let checkbox = Color(rgba: 0xb9b9_bbff)
    static let checkboxBackground = Color(rgba: 0xeeee_efff)

    
    /// Based on MarkdownUI's built-in GitHub theme, overriding only what we
    /// want to differ: base font size, inline-code accent, softer headings
    /// (no underline), roomier line-height, custom code block, and a
    /// header + zebra table style. Everything else (strong, link, blockquote,
    /// headings 4-6, task list, thematic break) is inherited from `.gitHub`.
    @MainActor
    static var enchantedTheme: Theme { Theme.gitHub
        .text {
            ForegroundColor(CodexTheme.primaryText)
            FontSize(ThemePreferences.bodyFontSize)
        }
        // Headings keep body size (14); differentiated by weight only.
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 22, bottom: 14)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 20, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(.em(1))
                }
        }
        // Custom code block: language label + copy button (functional, not
        // just styling), so kept instead of the plain GitHub default.
        .codeBlock { configuration in
            CodeBlockView(configuration: configuration)
        }
        // `.paragraph`, `.listItem`, `.table`, `.tableCell` inherited from `.gitHub`.
    }
}
