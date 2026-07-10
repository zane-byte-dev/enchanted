#if os(macOS)
import Foundation

enum VoiceRecognitionEngine: String, CaseIterable, Identifiable {
    case senseVoice
    case appleSpeech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .senseVoice: return "SenseVoice Small"
        case .appleSpeech: return "Apple Speech"
        }
    }
}

@MainActor
final class SpeechTranscriberRouter: SpeechTranscribing {
    private let apple = AppleSpeechTranscriber()
    private let senseVoice = SenseVoiceTranscriber()
    private var active: SpeechTranscribing?

    var displayName: String {
        active?.displayName ?? preferredEngine.displayName
    }

    func requestAuthorization() async throws {
        let selected: SpeechTranscribing
        if preferredEngine == .senseVoice, SenseVoiceModelManager.shared.isModelReady {
            selected = senseVoice
        } else {
            selected = apple
        }
        active = selected
        try await selected.requestAuthorization()
    }

    func start(
        onPartialResult: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        guard let active else {
            throw SpeechTranscriberError.recognizerUnavailable
        }
        try active.start(onPartialResult: onPartialResult, onFailure: onFailure)
    }

    func finish() async throws -> String {
        guard let active else { return "" }
        defer { self.active = nil }
        return try await active.finish()
    }

    func cancel() {
        active?.cancel()
        active = nil
    }

    func prewarm() async {
        guard preferredEngine == .senseVoice, SenseVoiceModelManager.shared.isModelReady else { return }
        await senseVoice.prewarm()
    }

    private var preferredEngine: VoiceRecognitionEngine {
        let value = UserDefaults.standard.string(forKey: VoiceInputPreferences.engineKey)
        return VoiceRecognitionEngine(rawValue: value ?? "") ?? .senseVoice
    }
}
#endif
