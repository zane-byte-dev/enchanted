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
    var onClick: () -> ()
    
    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 8) {
                Image(systemName: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 14))
                    .fontWeight(.regular)
                
                Spacer()
            }
        }
        .buttonStyle(SidebarRowStyle())
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fillColor(configuration))
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }

    private func fillColor(_ configuration: Configuration) -> Color {
        if isSelected || hover || configuration.isPressed {
            return Color.gray.opacity(0.05)
        }
        return .clear
    }
}

#Preview {
    SidebarButton(title: "Settings", image: "gearshape.fill", onClick: {})
}
