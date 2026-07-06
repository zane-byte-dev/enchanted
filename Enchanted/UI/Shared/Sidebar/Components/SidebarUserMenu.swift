//
//  SidebarUserMenu.swift
//  Enchanted
//
//  Popover that appears when the user taps the avatar at the bottom of the sidebar.
//

import SwiftUI

struct SidebarUserMenu: View {
    var onSettings: () -> ()

#if os(macOS)
    @State private var showCompletions    = false
    @State private var showShortcuts      = false
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "app.badge")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enchanted")
                        .font(.system(size: 13, weight: .semibold))
                    Text("本地 AI 助手")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

#if os(macOS)
            menuItem(icon: "textformat.abc", label: "Completions") {
                showCompletions = true
            }
            menuItem(icon: "keyboard", label: "Shortcuts") {
                showShortcuts = true
            }

            Divider()
#endif

            menuItem(icon: "gearshape", label: "Settings", shortcut: "⌘,") {
                onSettings()
            }
        }
        .frame(width: 220)
        .padding(.vertical, 4)
#if os(macOS)
        .sheet(isPresented: $showCompletions) {
            CompletionsEditor()
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsDemo()
        }
#endif
    }

    private func menuItem(icon: String, label: String, shortcut: String? = nil, action: @escaping () -> ()) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 16, height: 16)
                    .foregroundColor(Color(.label))
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(Color(.label))
                Spacer()
                if let sc = shortcut {
                    Text(sc)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((hover || configuration.isPressed) ? Color.gray.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }
}

#Preview {
    SidebarUserMenu(onSettings: {})
        .padding()
}
