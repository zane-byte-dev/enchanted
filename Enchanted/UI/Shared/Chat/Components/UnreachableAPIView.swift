//
//  UnreachableAPIView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

import SwiftUI
import ActivityIndicatorView

struct UnreachableAPIView: View {
    @State private var showSettings = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pi is unavailable. Go to Settings and check the Pi executable and working directory.")
                    .lineLimit(nil)
                    .fontWeight(.medium)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.label))
            }
            
            Spacer()
            
            ActivityIndicatorView(isVisible: .constant(true), type: .growingCircle)
                .frame(width: 21, height: 21)
                .accessibilityLabel(Text("Checking Pi connection"))
            
            Button(action: { showSettings.toggle() }) {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.accentColor, in: Capsule())
            .buttonStyle(GrowingButton())
            .accessibilityLabel(Text("Open settings"))
        }
        .padding()
        .background(Color(.systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.systemRed).opacity(0.2), lineWidth: 1)
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            Settings()
        }
    }
}

#Preview {
    UnreachableAPIView()
}
