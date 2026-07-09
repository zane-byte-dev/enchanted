//
//  KeyboardShortcuts.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 19/02/2024.
//

import SwiftUI

struct ShortcutRow: Identifiable {
    let id: Int
    var keys: [String]
    var description: String
}

struct KeyboardShortcutsDemo: View {
    @Environment(\.presentationMode) var presentationMode
    var shortcuts = [
        ShortcutRow(id: 1, keys: ["⌃", "⌘", "K"], description: "Open Panel Window"),
        ShortcutRow(id: 2, keys: ["⌘", "N"], description: "New Conversation"),
        ShortcutRow(id: 3, keys: ["⌘", "⌥", "S"], description: "Hide/Show sidebar"),
        ShortcutRow(id: 4, keys: ["⌘", "V"], description: "Paste text or image from clipboard into message box ")
    ]
    
    private func close() {
        presentationMode.wrappedValue.dismiss()
    }
    
    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Text("Shortcuts")
                    .font(.title)
                    .fontWeight(.thin)
                    .enchantify()
                    .padding(.bottom, 30)
                
                Spacer()
                
                Button(action: close) {
                    Text("Close")
                }
                .buttonStyle(GrowingButton())
            }
            
            Table(shortcuts) {
                TableColumn("快捷键") { shortcut in
                    Text(shortcut.keys.joined(separator: " + "))
                }
                .width(min: 100, max: 150)
                TableColumn("说明") { shortcut in
                    Text(String(shortcut.description))
                }
            }
        }
        .padding()
        .frame(width: 800, height: 600)
    }
}

#Preview {
    KeyboardShortcutsDemo()
}
