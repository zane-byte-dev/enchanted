#if os(macOS)
import AVFoundation
import Foundation
import SherpaOnnx

enum SenseVoiceTranscriberError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case noAudio
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "SenseVoice Small 尚未下载，请到“设置 > 语音”下载模型。"
        case .modelLoadFailed: return "SenseVoice Small 加载失败，请删除模型后重新下载。"
        case .noAudio: return "没有录到有效语音，请检查麦克风后重试。"
        case .recognitionFailed: return "SenseVoice 没有生成识别结果。"
        }
    }
}

@MainActor
final class SenseVoiceTranscriber: SpeechTranscribing {
    let displayName = "SenseVoice Small"

    private var audioEngine: AVAudioEngine?
    private var inputTapInstalled = false
    private var accumulator = SenseVoiceAudioAccumulator()

    func requestAuthorization() async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            authorized = false
        }
        guard authorized else { throw SpeechTranscriberError.microphoneDenied }
        guard SenseVoiceModelManager.shared.modelFiles != nil else {
            throw SenseVoiceTranscriberError.modelMissing
        }
    }

    func start(
        onPartialResult: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        cancel()
        guard SenseVoiceModelManager.shared.modelFiles != nil else {
            throw SenseVoiceTranscriberError.modelMissing
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechTranscriberError.invalidAudioInput
        }

        let accumulator = SenseVoiceAudioAccumulator()
        self.accumulator = accumulator
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            accumulator.append(buffer, sampleRate: format.sampleRate)
        }
        inputTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
            throw error
        }
        audioEngine = engine
    }

    func finish() async throws -> String {
        stopCapture()
        let audio = accumulator.snapshot()
        guard audio.samples.count >= max(1, Int(audio.sampleRate / 10)) else {
            throw SenseVoiceTranscriberError.noAudio
        }
        guard let files = SenseVoiceModelManager.shared.modelFiles else {
            throw SenseVoiceTranscriberError.modelMissing
        }
        let text = try await SenseVoiceInferenceEngine.shared.transcribe(
            samples: audio.samples,
            sampleRate: Int(audio.sampleRate),
            files: files,
            language: VoiceInputPreferences.senseVoiceLanguage
        )
        return Self.clean(text)
    }

    func cancel() {
        stopCapture()
        accumulator.reset()
    }

    func prewarm() async {
        guard let files = SenseVoiceModelManager.shared.modelFiles else { return }
        try? await SenseVoiceInferenceEngine.shared.prepare(
            files: files,
            language: VoiceInputPreferences.senseVoiceLanguage
        )
    }

    private func stopCapture() {
        audioEngine?.stop()
        if inputTapInstalled, let input = audioEngine?.inputNode {
            input.removeTap(onBus: 0)
        }
        inputTapInstalled = false
        audioEngine = nil
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<\\|[^|>]+\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([，。！？；：,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SenseVoiceAudioAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000

    func append(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        self.sampleRate = sampleRate
        samples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
        lock.unlock()
    }

    func snapshot() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, sampleRate)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

actor SenseVoiceInferenceEngine {
    static let shared = SenseVoiceInferenceEngine()

    nonisolated(unsafe) private var recognizer: OpaquePointer?
    private var configurationKey = ""

    deinit {
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    }

    func prepare(files: SenseVoiceModelFiles, language: String) throws {
        let key = "\(files.model.path)|\(files.tokens.path)|\(language)"
        guard recognizer == nil || key != configurationKey else { return }
        unload()

        let created = files.model.path.withCString { modelPath in
            files.tokens.path.withCString { tokensPath in
                language.withCString { languageHint in
                    "cpu".withCString { provider in
                        "greedy_search".withCString { decodingMethod in
                            var senseVoice = SherpaOnnxOfflineSenseVoiceModelConfig()
                            senseVoice.model = modelPath
                            senseVoice.language = languageHint
                            senseVoice.use_itn = 1

                            var model = SherpaOnnxOfflineModelConfig()
                            model.tokens = tokensPath
                            model.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
                            model.provider = provider
                            model.sense_voice = senseVoice

                            var config = SherpaOnnxOfflineRecognizerConfig()
                            config.feat_config.sample_rate = 16_000
                            config.feat_config.feature_dim = 80
                            config.model_config = model
                            config.decoding_method = decodingMethod
                            config.max_active_paths = 4
                            return SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }
        guard let created else { throw SenseVoiceTranscriberError.modelLoadFailed }
        recognizer = created
        configurationKey = key
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        files: SenseVoiceModelFiles,
        language: String
    ) throws -> String {
        try prepare(files: files, language: language)
        guard let recognizer, let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw SenseVoiceTranscriberError.recognitionFailed
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                Int32(sampleRate),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw SenseVoiceTranscriberError.recognitionFailed
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let value = result.pointee.text else {
            throw SenseVoiceTranscriberError.recognitionFailed
        }
        return String(cString: value)
    }

    func unload() {
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
        recognizer = nil
        configurationKey = ""
    }
}
#endif
