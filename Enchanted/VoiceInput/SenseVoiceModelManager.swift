#if os(macOS)
import Combine
import CryptoKit
import Foundation

struct SenseVoiceModelFiles: Sendable {
    let model: URL
    let tokens: URL
}

enum SenseVoiceModelState: Equatable {
    case missing
    case downloading(Double)
    case installing
    case ready
    case failed(String)
}

enum SenseVoiceModelError: LocalizedError {
    case downloadFailed
    case checksumMismatch
    case extractionFailed
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "SenseVoice 模型下载失败。"
        case .checksumMismatch: return "SenseVoice 模型校验失败，请重新下载。"
        case .extractionFailed: return "SenseVoice 模型解压失败。"
        case .invalidModel: return "SenseVoice 模型文件不完整，请重新下载。"
        }
    }
}

@MainActor
final class SenseVoiceModelManager: ObservableObject {
    static let shared = SenseVoiceModelManager()

    static let archiveURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
    )!
    nonisolated static let archiveSHA256 = "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e"

    @Published private(set) var state: SenseVoiceModelState = .missing
    private var downloader: SenseVoiceDownloadClient?
    private var downloadTask: Task<Void, Never>?

    private init() {
        refreshState()
    }

    var modelDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Enchanted", isDirectory: true)
            .appendingPathComponent("VoiceModels", isDirectory: true)
            .appendingPathComponent("SenseVoiceSmall-int8-2024-07-17", isDirectory: true)
    }

    var modelFiles: SenseVoiceModelFiles? {
        let files = SenseVoiceModelFiles(
            model: modelDirectory.appendingPathComponent("model.int8.onnx"),
            tokens: modelDirectory.appendingPathComponent("tokens.txt")
        )
        return Self.isValid(files) ? files : nil
    }

    var isModelReady: Bool { modelFiles != nil }

    func refreshState() {
        guard !isDownloading else { return }
        state = isModelReady ? .ready : .missing
    }

    func downloadModel() {
        guard !isDownloading else { return }
        downloadTask = Task { [weak self] in
            await self?.performDownload()
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        downloadTask?.cancel()
        downloadTask = nil
        refreshState()
    }

    func deleteModel() {
        cancelDownload()
        do {
            if FileManager.default.fileExists(atPath: modelDirectory.path) {
                try FileManager.default.removeItem(at: modelDirectory)
            }
            state = .missing
            Task { await SenseVoiceInferenceEngine.shared.unload() }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var isDownloading: Bool {
        switch state {
        case .downloading, .installing: return true
        case .missing, .ready, .failed: return false
        }
    }

    private func performDownload() async {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("Enchanted-SenseVoice-\(UUID().uuidString).tar.bz2")
        let client = SenseVoiceDownloadClient()
        downloader = client
        state = .downloading(0)

        do {
            try await client.download(from: Self.archiveURL, to: archive) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress)
                }
            }
            try Task.checkCancellation()
            state = .installing
            let destination = modelDirectory
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyArchive(at: archive)
                try Self.extractArchive(at: archive, to: destination)
            }.value
            state = .ready
        } catch is CancellationError {
            refreshState()
        } catch {
            state = .failed(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: archive)
        downloader = nil
        downloadTask = nil
    }

    nonisolated private static func verifyArchive(at url: URL) throws {
        guard !archiveSHA256.isEmpty else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 4 * 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == archiveSHA256 else { throw SenseVoiceModelError.checksumMismatch }
    }

    nonisolated private static func extractArchive(at archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("Enchanted-SenseVoice-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SenseVoiceModelError.extractionFailed }

        let candidates = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let extracted = candidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("model.int8.onnx").path)
        }) else {
            throw SenseVoiceModelError.invalidModel
        }
        let files = SenseVoiceModelFiles(
            model: extracted.appendingPathComponent("model.int8.onnx"),
            tokens: extracted.appendingPathComponent("tokens.txt")
        )
        guard isValid(files) else { throw SenseVoiceModelError.invalidModel }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: extracted, to: destination)
    }

    nonisolated private static func isValid(_ files: SenseVoiceModelFiles) -> Bool {
        let fm = FileManager.default
        guard
            let modelSize = (try? fm.attributesOfItem(atPath: files.model.path)[.size]) as? NSNumber,
            let tokenSize = (try? fm.attributesOfItem(atPath: files.tokens.path)[.size]) as? NSNumber
        else { return false }
        return modelSize.int64Value > 100_000_000 && tokenSize.int64Value > 100_000
    }
}

private final class SenseVoiceDownloadClient: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var progress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.destination = destination
                self.progress = progress
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: source)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let destination else { throw SenseVoiceModelError.downloadFailed }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(throwing: error)
        } else {
            finish(throwing: nil)
        }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        session?.finishTasksAndInvalidate()
    }
}
#endif
