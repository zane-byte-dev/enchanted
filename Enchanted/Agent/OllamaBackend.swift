//
//  OllamaBackend.swift
//  Enchanted
//
//  Default backend: adapts the existing OllamaKit integration to `AgentBackend`.
//  Keeps the app behaving exactly as before while proving the abstraction.
//

import Foundation
import Combine
import OllamaKit

struct OllamaBackend: AgentBackend {
    func chat(model: String, messages: [AgentChatMessage]) -> AnyPublisher<AgentEvent, Error> {
        let okMessages = messages.map { m in
            OKChatRequestData.Message(
                role: OKChatRequestData.Message.Role(rawValue: m.role.rawValue) ?? .assistant,
                content: m.content,
                images: m.imagesBase64
            )
        }

        var request = OKChatRequestData(model: model, messages: okMessages)
        request.options = OKCompletionOptions(temperature: 0)

        return OllamaService.shared.ollamaKit.chat(data: request)
            .compactMap { (response: OKChatResponse) -> AgentEvent? in
                guard let content = response.message?.content, !content.isEmpty else { return nil }
                return .messageDelta(content)
            }
            .mapError { $0 as Error }
            .eraseToAnyPublisher()
    }

    func models() async throws -> [LanguageModel] {
        try await OllamaService.shared.getModels()
    }

    func reachable() async -> Bool {
        await OllamaService.shared.reachable()
    }
}
