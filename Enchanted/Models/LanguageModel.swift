//
//  LanguageModel.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/05/2024.
//

import Foundation

struct LanguageModel {
    var name: String
    var provider: ModelProvider
    /// Raw pi provider id. `ModelProvider` is only the icon/known-provider
    /// projection and cannot represent extension-defined providers.
    var providerID: String? = nil
    var imageSupport: Bool
}

enum ModelProvider: String, Codable, Equatable, Hashable {
    case openai
    case anthropic
    case google
    case xai
    case groq
    case deepseek
    case mistral
    case idealab
    case opencodeGo = "opencode-go"
    case unknown

    var iconName: String {
        switch self {
        case .openai: return "sparkles"
        case .anthropic: return "brain.head.profile"
        case .google: return "g.circle"
        case .xai: return "xmark"
        case .groq: return "bolt"
        case .deepseek: return "magnifyingglass"
        case .mistral: return "wind"
        case .idealab: return "lightbulb"
        case .opencodeGo: return "network"
        case .unknown: return "cpu"
        }
    }
}
