#if os(macOS)
import Combine
import Foundation

struct VoiceTextProcessingResult {
    let text: String
    let usedAI: Bool
    let warning: String?
}

@MainActor
final class VoiceTextProcessor {
    private lazy var backend: AgentBackend = AgentBackendConfig.makeBackend()
    private var activeRequest: OneShotAgentRequest?

    func process(_ transcript: String) async -> VoiceTextProcessingResult {
        var text = normalize(transcript)
        for replacement in VoiceInputPreferences.replacements {
            text = text.replacingOccurrences(of: replacement.source, with: replacement.target)
        }

        guard VoiceInputPreferences.aiCorrectionEnabled else {
            return .init(text: finalize(text), usedAI: false, warning: nil)
        }
        guard let model = LanguageModelStore.shared.selectedModel?.name, !model.isEmpty else {
            return .init(
                text: finalize(text),
                usedAI: false,
                warning: "没有可用的 AI 模型，已使用原始转写。"
            )
        }

        let request = OneShotAgentRequest()
        activeRequest = request
        let prompt = """
        你是语音输入纠错器。请整理下面的口述转写：
        - 只修正明显的同音错字、标点、重复和无意义口头语。
        - 保留原语言、原意、语气、专有名词、代码和数字。
        - 不回答内容，不扩写，不解释。
        - 只输出可直接粘贴的最终文本，不要引号或 Markdown。

        转写：
        \(text)
        """

        let publisher = backend.chat(
            model: model,
            messages: [AgentChatMessage(role: .user, content: prompt)]
        )
        let corrected = await request.run(publisher: publisher, timeout: 10)
        if activeRequest === request {
            activeRequest = nil
        }

        guard let corrected, !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            (backend as? PiConnector)?.abort()
            return .init(
                text: finalize(text),
                usedAI: false,
                warning: "AI 润色超时或失败，已使用原始转写。"
            )
        }
        return .init(text: finalize(sanitize(corrected)), usedAI: true, warning: nil)
    }

    func cancel() {
        activeRequest?.cancel()
        activeRequest = nil
        (backend as? PiConnector)?.abort()
    }

    private func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") && result.hasSuffix("```") {
            result = result.replacingOccurrences(
                of: "^```(?:text)?\\s*|\\s*```$",
                with: "",
                options: .regularExpression
            )
        }
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            result.removeFirst()
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalize(_ value: String) -> String {
        guard VoiceInputPreferences.removeTrailingPeriod else { return value }
        var result = value
        if let last = result.last, ["。", "."].contains(last) {
            result.removeLast()
        }
        return result
    }
}

/// Bridges the existing Combine backend API to one bounded async result.
private final class OneShotAgentRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var cancellable: AnyCancellable?
    private var output = ""
    private var completed = false

    func run(publisher: AnyPublisher<AgentEvent, Error>, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let subscription = publisher.sink { [weak self] completion in
                switch completion {
                case .finished:
                    self?.finish()
                case .failure:
                    self?.finish(value: nil)
                }
            } receiveValue: { [weak self] event in
                self?.receive(event)
            }

            lock.lock()
            if completed {
                lock.unlock()
                subscription.cancel()
            } else {
                cancellable = subscription
                lock.unlock()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(value: nil)
            }
        }
    }

    func cancel() {
        finish(value: nil)
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .messageDelta(let text):
            lock.lock()
            if !completed { output += text }
            lock.unlock()
        case .done:
            finish()
        case .thinkingDelta, .toolStart, .toolEnd, .queueUpdate, .queuedTurnStarted,
             .compactionStarted, .compactionFinished, .uiRequest, .planUpdate:
            break
        }
    }

    private func finish(value: String? = nil) {
        let continuation: CheckedContinuation<String?, Never>?
        let result: String?
        let subscription: AnyCancellable?

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        result = value ?? (output.isEmpty ? nil : output)
        subscription = cancellable
        cancellable = nil
        lock.unlock()

        subscription?.cancel()
        continuation?.resume(returning: result)
    }
}
#endif
