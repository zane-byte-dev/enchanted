//
//  Binding+Extension.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 22/12/2023.
//

import SwiftUI

extension Binding {
    @MainActor
    func onChange(_ handler: @escaping @MainActor (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}
