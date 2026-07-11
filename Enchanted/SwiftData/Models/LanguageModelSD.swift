//
//  ModelSD.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData

@Model
final class LanguageModelSD: Identifiable {
    @Attribute(.unique) var name: String
    var isAvailable: Bool = false
    var imageSupport: Bool = false
    @Attribute var modelProvider: ModelProvider? = ModelProvider.unknown
    /// Preserves custom/extension provider ids that are not enum cases.
    @Attribute var providerID: String?
    
    @Relationship(deleteRule: .cascade, inverse: \ConversationSD.model)
    var conversations: [ConversationSD]? = []
    
    
    init(name: String, imageSupport: Bool = false, modelProvider: ModelProvider, providerID: String? = nil) {
        self.name = name
        self.imageSupport = imageSupport
        self.modelProvider = modelProvider
        self.providerID = providerID ?? modelProvider.rawValue
    }
    
    @Transient var isNotAvailable: Bool {
        isAvailable == false
    }
}

// MARK: - Helpers
extension LanguageModelSD {
    var providerDisplayName: String {
        let raw = providerID ?? modelProvider?.rawValue ?? ModelProvider.unknown.rawValue
        return raw.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    var prettyName: String {
        guard let modelName = name.components(separatedBy: ":").first else {
            return name
        }
        
        return modelName.capitalized
    }
    
    var prettyVersion: String {
        let components = name.components(separatedBy: ":")
        if components.count >= 2 {
            return components[1]
        }
        return ""
    }
    
    var supportsImages: Bool {
        if imageSupport {
            return true
        }
        
        /// older technique to detect image modality
        /// @deprecated
        let imageSupportedModels = ["llava"]
        for modelName in imageSupportedModels {
            if name.contains(modelName) {
                return true
            }
        }
        return false
    }
    
    @MainActor static let sample: [LanguageModelSD] = [
        .init(name: "example-model", modelProvider: .unknown)
    ]
}


// See MessageSD's Sendable note.
