//
//  ModelSelector.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 11/12/2023.
//

import SwiftUI

struct ModelSelectorView: View {
    var modelsList: [LanguageModelSD]
    var selectedModel: LanguageModelSD?
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    var showChevron = true
    
    var body: some View {
        Menu {
            ForEach(modelsList, id: \.self) { model in
                Button(action: {
                    withAnimation(.easeOut) {    
                        onSelectModel(model)
                    }
                }) {
                    HStack {
                        Image(systemName: model.modelProvider?.iconName ?? "cpu")
                        Text(model.name)
                            .font(.body)
                    }
                    .tag(model.name)
                }
            }
        } label: {
            HStack(alignment: .center) {
                if let selectedModel = selectedModel {
                    HStack(alignment: .bottom, spacing: 5) {
                        
                        #if os(macOS) || os(visionOS)
                        HStack(spacing: 4) {
                            Image(systemName: selectedModel.modelProvider?.iconName ?? "cpu")
                                .font(.system(size: 11))
                                .foregroundColor(CodexTheme.mutedText)
                            Text(selectedModel.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        #elseif os(iOS)
                        Text(selectedModel.prettyName )
                            .font(.body)
                            .foregroundColor(Color.labelCustom)
                        
                        Text(selectedModel.prettyVersion)
                            .font(.subheadline)
                            .foregroundColor(Color.gray3Custom)
                        #endif
                    }
                }
                
                Image(systemName: "chevron.down")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10)
                    .foregroundColor(CodexTheme.faintText)
                    .showIf(showChevron)
            }
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
#endif
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

#Preview {
    ModelSelectorView(
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0], 
        onSelectModel: {_ in},
        showChevron: false
    )
}
