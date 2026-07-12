#if os(macOS)
import AVFoundation
import Foundation
import Speech

@MainActor
protocol SpeechTranscribing: AnyObject {
    var displayName: String { get }
    func requestAuthorization() async throws
    func start(
        onPartialResult: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws
    func finish() async throws -> String
    func cancel()
    func prewarm() async
}

extension SpeechTranscribing {
    func prewarm() async {}
}

enum SpeechTranscriberError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case invalidAudioInput

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "没有麦克风权限，请在系统设置中允许 Mox 使用麦克风。"
        case .speechRecognitionDenied:
            return "没有语音识别权限，请在系统设置中允许 Mox 使用语音识别。"
        case .recognizerUnavailable:
            return "系统语音识别当前不可用。"
        case .onDeviceRecognitionUnavailable:
            return "所选语言不支持设备端识别，请关闭“仅使用本地识别”或更换语言。"
        case .invalidAudioInput:
            return "没有找到可用的音频输入设备。"
        }
    }
}

/// Apple Speech implementation of the transcription boundary. A local model can
/// replace this type later without changing the shortcut, overlay, or injection flow.
@MainActor
final class AppleSpeechTranscriber: SpeechTranscribing {
    let displayName = "Apple Speech"
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var latestTranscript = ""
    private var isFinishing = false

    func requestAuthorization() async throws {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else {
            throw SpeechTranscriberError.speechRecognitionDenied
        }

        let microphoneAuthorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            microphoneAuthorized = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            microphoneAuthorized = false
        }
        guard microphoneAuthorized else {
            throw SpeechTranscriberError.microphoneDenied
        }
    }

    func start(
        onPartialResult: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: VoiceInputPreferences.locale), recognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable
        }
        self.recognizer = recognizer

        latestTranscript = ""
        isFinishing = false

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = VoiceInputPreferences.contextualTerms
        if VoiceInputPreferences.onDeviceOnly {
            guard recognizer.supportsOnDeviceRecognition else {
                throw SpeechTranscriberError.onDeviceRecognitionUnavailable
            }
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechTranscriberError.invalidAudioInput
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        inputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
            throw error
        }

        audioEngine = engine
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString {
                    self.latestTranscript = text
                    onPartialResult(text)
                }
                if let error, !self.isFinishing {
                    onFailure(error)
                }
            }
        }
    }

    func finish() async throws -> String {
        isFinishing = true
        stopAudioCapture()
        recognitionRequest?.endAudio()

        // Give Speech a short window to turn the last audio buffers into a final result.
        try? await Task.sleep(for: .milliseconds(350))
        recognitionTask?.cancel()
        clearRecognitionObjects()
        return latestTranscript
    }

    func cancel() {
        isFinishing = true
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        clearRecognitionObjects()
        latestTranscript = ""
    }

    private func stopAudioCapture() {
        audioEngine?.stop()
        if inputTapInstalled, let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }
        inputTapInstalled = false
        audioEngine = nil
    }

    private func clearRecognitionObjects() {
        recognizer = nil
        recognitionRequest = nil
        recognitionTask = nil
    }
}
#endif
