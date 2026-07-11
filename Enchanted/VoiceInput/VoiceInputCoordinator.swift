#if os(macOS)
import AppKit
import Foundation
import OSLog

enum VoiceInputState: Equatable {
    case idle
    case requestingPermission
    case recording(String)
    case processing
    case success(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .requestingPermission, .recording, .processing:
            return true
        case .idle, .success, .failed:
            return false
        }
    }
}

@MainActor
final class VoiceInputCoordinator: ObservableObject {
    static let shared = VoiceInputCoordinator()

    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastResultWasInjected = false
    @Published private(set) var lastUsedAI = false
    @Published private(set) var lastProcessingWarning: String?
    @Published private(set) var activeEngineName = ""

    private let transcriber: SpeechTranscribing
    private let injector: TextInjectionService
    private let textProcessor: VoiceTextProcessor
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "subj.Enchanted", category: "VoiceInput")
    private var targetApplication: NSRunningApplication?
    private var operationTask: Task<Void, Never>?
    private var stopRequested = false
    private var shouldInjectResult = true
    private var generation = 0
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    init(
        transcriber: SpeechTranscribing? = nil,
        injector: TextInjectionService? = nil,
        textProcessor: VoiceTextProcessor? = nil
    ) {
        self.transcriber = transcriber ?? SpeechTranscriberRouter()
        self.injector = injector ?? TextInjectionService()
        self.textProcessor = textProcessor ?? VoiceTextProcessor()
    }

    func shortcutKeyDown() {
        beginRecording(shouldInjectResult: true)
    }

    func prewarm() async {
        await transcriber.prewarm()
    }

    func shortcutKeyUp() {
        stopRequested = true
        guard case .recording = state else { return }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            await self?.finishRecording()
        }
    }

    /// Used by the Voice page for testing without holding the global shortcut.
    func toggleRecording() {
        switch state {
        case .idle, .success, .failed:
            beginRecording(shouldInjectResult: false)
        case .requestingPermission, .recording:
            shortcutKeyUp()
        case .processing:
            break
        }
    }

    func cancel() {
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        stopRequested = false
        transcriber.cancel()
        textProcessor.cancel()
        removeEscapeMonitors()
        transition(to: .idle)
    }

    private func beginRecording(shouldInjectResult: Bool) {
        switch state {
        case .idle, .success, .failed:
            break
        case .requestingPermission, .recording, .processing:
            return
        }

        generation += 1
        let currentGeneration = generation
        stopRequested = false
        self.shouldInjectResult = shouldInjectResult
        lastProcessingWarning = nil
        targetApplication = NSWorkspace.shared.frontmostApplication
        installEscapeMonitors()
        transition(to: .requestingPermission)

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriber.requestAuthorization()
                guard currentGeneration == generation else { return }
                activeEngineName = transcriber.displayName
                try transcriber.start(
                    onPartialResult: { [weak self] text in
                        self?.handlePartialResult(text)
                    },
                    onFailure: { [weak self] error in
                        self?.fail(error)
                    }
                )
                guard currentGeneration == generation else { return }
                transition(to: .recording(""))
                if stopRequested {
                    await finishRecording()
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
    }

    private func finishRecording() async {
        guard case .recording = state else { return }
        transition(to: .processing)

        let rawTranscript: String
        do {
            rawTranscript = try await transcriber.finish()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            fail(error)
            return
        }
        guard !rawTranscript.isEmpty else {
            failMessage("没有识别到语音，请再试一次。")
            return
        }

        let processed = await textProcessor.process(rawTranscript)
        guard case .processing = state else { return }
        let transcript = processed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            failMessage("文本整理后没有可粘贴的内容。")
            return
        }
        lastUsedAI = processed.usedAI
        lastProcessingWarning = processed.warning

        if shouldInjectResult {
            do {
                try await injector.inject(transcript, into: targetApplication)
                lastResultWasInjected = true
            } catch {
                fail(error)
                return
            }
        } else {
            lastResultWasInjected = false
        }

        lastTranscript = transcript
        removeEscapeMonitors()
        transition(to: .success(transcript))
        scheduleReset(after: .milliseconds(850))
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
    }

    private func handlePartialResult(_ text: String) {
        guard case .recording = state else { return }
        transition(to: .recording(text))
    }

    private func failMessage(_ message: String) {
        transcriber.cancel()
        textProcessor.cancel()
        removeEscapeMonitors()
        transition(to: .failed(message))
        scheduleReset(after: .seconds(4))
    }

    private func scheduleReset(after duration: Duration) {
        generation += 1
        let currentGeneration = generation
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, currentGeneration == generation else { return }
            transition(to: .idle)
        }
    }

    private func transition(to newState: VoiceInputState) {
        state = newState
        logger.debug("Voice input state changed to \(newState.logName, privacy: .public)")
        switch newState {
        case .idle:
            VoiceOverlayController.shared.hide()
        default:
            VoiceOverlayController.shared.show(coordinator: self)
        }
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.cancel() }
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
    }

    private func removeEscapeMonitors() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
    }
}

private extension VoiceInputState {
    var logName: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermission: return "requestingPermission"
        case .recording: return "recording"
        case .processing: return "processing"
        case .success: return "success"
        case .failed: return "failed"
        }
    }
}
#endif
