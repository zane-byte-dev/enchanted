//
//  Menus.swift
//  Enchanted
//
//  Created by Wildan Zulfikar on 24.4.2024.
//

import Foundation
import SwiftUI

#if os(macOS)
struct ShowSettingsKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var showSettings: Binding<Bool>? {
        get { self[ShowSettingsKey.self] }
        set { self[ShowSettingsKey.self] = newValue }
    }
}

struct Menus: Commands {
   @FocusedValue(\.showSettings) var showSettings
   @ObservedObject private var store = ShortcutStore.shared

   var body: some Commands {
       CommandGroup(replacing: .appSettings) {
           Button("Settings") {
               showSettings?.wrappedValue = true
           }
           .shortcut(store.effective("settings"))
       }
  }
}
#endif
