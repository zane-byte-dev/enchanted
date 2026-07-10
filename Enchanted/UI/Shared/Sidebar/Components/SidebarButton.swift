//
//  SidebarButton.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 19/02/2024.
//

import SwiftUI

struct SidebarButton: View {
    var title: String
    var image: String
    var shortcutCommandID: String?
    var onClick: () -> ()

    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @State private var hovering = false

    private var shortcutHint: String {
        guard let shortcutCommandID else { return "" }
        return shortcutStore.effective(shortcutCommandID)?.displayKeys.joined() ?? ""
    }
    
    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 8) {
                Image(systemName: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .fontWeight(.regular)
                
                Spacer()

                if hovering && !shortcutHint.isEmpty {
                    Text(shortcutHint)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.78))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
        }
        .buttonStyle(SidebarRowStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Shared sidebar row: consistent insets + hover / pressed / active highlight.
struct SidebarRowStyle: ButtonStyle {
    var isSelected: Bool = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor(configuration))
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }

    private func fillColor(_ configuration: Configuration) -> Color {
        if isSelected || hover || configuration.isPressed {
            return isSelected ? CodexTheme.rowSelected : CodexTheme.rowHover
        }
        return .clear
    }
}

#Preview {
    SidebarButton(title: "Settings", image: "gearshape.fill", shortcutCommandID: "settings", onClick: {})
}
