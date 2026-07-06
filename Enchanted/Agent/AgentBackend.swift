//
//  AgentBackend.swift
//  Enchanted
//
//  Unified backend abstraction so the app can talk to any agent CLI/server
//  (Ollama, pi, neo, wanda) through one streaming protocol.
//

import Foundation
import Combine

/// Neutral chat message handed to any agent backend.
/// Decoupled from OllamaKit so backends can map it to their own wire format.
struct AgentChatMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
    let imagesBase64: [String]

    init(role: Role, content: String, imagesBase64: [String] = []) {
        self.role = role
        self.content = content
        self.imagesBase64 = imagesBase64
    }
}

/// Unified streaming event emitted by every backend.
/// This is the app-side mirror of pi's RPC event stream / ACP.
enum AgentEvent: Sendable {
    /// Incremental assistant text.
    case messageDelta(String)
    /// Incremental reasoning / thinking text.
    case thinkingDelta(String)
    /// A tool call started (callId, name, JSON args string).
    case toolStart(callId: String, name: String, args: String)
    /// A tool call finished.
    case toolEnd(callId: String, name: String, result: String, isError: Bool)
    /// Generation completed successfully.
    case done
}

/// Any agent that can stream a chat completion.
///
/// Implementations:
/// - `OllamaBackend`  – wraps the existing OllamaKit path (stateless per request).
/// - `PiConnector`    – drives `pi --mode rpc` over JSONL stdio (stateful session).
protocol AgentBackend: Sendable {
    /// Stream a chat completion. Emits `AgentEvent`s, then completes (or errors).
    func chat(model: String, messages: [AgentChatMessage]) -> AnyPublisher<AgentEvent, Error>

    /// List available models.
    func models() async throws -> [LanguageModel]

    /// Whether the backend is reachable / can start.
    func reachable() async -> Bool
}
