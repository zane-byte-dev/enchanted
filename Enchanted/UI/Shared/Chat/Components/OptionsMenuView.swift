//
//  OptionsMenuView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/05/2024.
//

import SwiftUI

struct MoreOptionsMenuView: View {
    var copyChat: (_ json: Bool) -> ()
    var body: some View {
        Menu {
            Button(action: {copyChat(false)}) {
                Text("Copy Chat")
            }
            Button(action: {copyChat(true)}) {
                Text("Copy Chat as JSON")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CodexTheme.mutedText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
#endif
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

#Preview {
    MoreOptionsMenuView(copyChat: {_ in})
}
