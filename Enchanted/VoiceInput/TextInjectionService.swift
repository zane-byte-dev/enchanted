#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

enum TextInjectionError: LocalizedError {
    case accessibilityDenied
    case targetApplicationUnavailable
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "需要辅助功能权限才能把文字粘贴到当前应用。"
        case .targetApplicationUnavailable:
            return "开始录音时使用的应用已经关闭。"
        case .pasteboardWriteFailed:
            return "无法写入系统剪贴板。"
        }
    }
}

@MainActor
final class TextInjectionService {
    func inject(_ text: String, into application: NSRunningApplication?) async throws {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw TextInjectionError.accessibilityDenied
        }
        guard let application, !application.isTerminated else {
            throw TextInjectionError.targetApplicationUnavailable
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            throw TextInjectionError.pasteboardWriteFailed
        }
        let injectedChangeCount = pasteboard.changeCount

        application.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(140))
        Accessibility.simulatePasteCommand()
        try? await Task.sleep(for: .milliseconds(320))

        // Do not overwrite clipboard content another app created during injection.
        if pasteboard.changeCount == injectedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }
}

private struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
#endif
