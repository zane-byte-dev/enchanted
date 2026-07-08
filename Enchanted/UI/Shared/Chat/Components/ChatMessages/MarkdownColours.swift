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

    // Inline code (`code`): subtle wrap + accent text colour.
    static let inlineCodeText = Color(
        light: Color(rgba: 0xd633_6cff), dark: Color(rgba: 0xf19a_b1ff)
    )
    static let inlineCodeBackground = Color(
        light: Color(rgba: 0xf1f3_f5ff), dark: Color(rgba: 0x2b2d_33ff)
    )

    // Tables: light header + horizontal zebra striping.
    static let tableHeaderBackground = Color(
        light: Color(rgba: 0xf3f4_f6ff), dark: Color(rgba: 0x2526_2aff)
    )
    static let tableRowAlt = Color(
        light: Color(rgba: 0xf8f9_faff), dark: Color(rgba: 0x2021_26ff)
    )
    
    static let enchantedTheme = Theme()
        .text {
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(inlineCodeText)
            BackgroundColor(inlineCodeBackground)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(link)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(.em(1.5))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 22, bottom: 14)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(.em(1.3))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 20, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(.em(1.15))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.875))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.85))
                    ForegroundColor(tertiaryText)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.4))
                .markdownMargin(top: 0, bottom: 16)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(border)
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(secondaryText) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            CodeBlockView(configuration: configuration)
        }
        .listItem { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.4))
                .markdownMargin(top: 0, bottom: 6)
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(checkbox, checkboxBackground)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: border))
                // Header row gets a light fill; data rows use horizontal zebra
                // striping (row 0 = header, data rows start at 1).
                .markdownTableBackgroundStyle(
                    TableBackgroundStyle { row, _ in
                        if row == 0 { return tableHeaderBackground }
                        return row.isMultiple(of: 2) ? tableRowAlt : background
                    }
                )
                .markdownMargin(top: 0, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .relativeLineSpacing(.em(0.3))
        }
        .thematicBreak {
            Divider()
                .relativeFrame(height: .em(0.25))
                .overlay(border)
                .markdownMargin(top: 24, bottom: 24)
        }
}
