#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class VoiceOverlayController {
    static let shared = VoiceOverlayController()

    private var panel: NSPanel?

    func show(coordinator: VoiceInputCoordinator) {
        let panel = panel ?? makePanel(coordinator: coordinator)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(coordinator: VoiceInputCoordinator) -> NSPanel {
        let size = NSSize(width: 390, height: 82)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: VoiceOverlayView(coordinator: coordinator))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 56
        )
        panel.setFrameOrigin(origin)
    }
}

private struct VoiceOverlayView: View {
    @ObservedObject var coordinator: VoiceInputCoordinator

    var body: some View {
        HStack(spacing: 14) {
            stateSymbol
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if coordinator.state.isActive {
                Button {
                    coordinator.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: Circle())
                .help("取消（Esc）")
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 390, height: 82)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var stateSymbol: some View {
        switch coordinator.state {
        case .requestingPermission, .processing:
            ProgressView()
                .controlSize(.small)
        case .recording:
            TimelineView(.animation(minimumInterval: 0.12)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 8 + abs(sin(phase * 5 + Double(index))) * 16)
                    }
                }
            }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 24))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 22))
        case .idle:
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
        }
    }

    private var title: String {
        switch coordinator.state {
        case .idle: return "语音输入"
        case .requestingPermission: return "正在准备麦克风…"
        case .recording:
            return coordinator.activeEngineName.isEmpty
                ? "正在聆听"
                : "正在聆听 · \(coordinator.activeEngineName)"
        case .processing: return "正在整理文字…"
        case .success: return coordinator.lastResultWasInjected ? "已粘贴" : "识别完成"
        case .failed: return "语音输入失败"
        }
    }

    private var detail: String {
        switch coordinator.state {
        case .idle:
            return "按住快捷键开始说话"
        case .requestingPermission:
            return "首次使用需要授权"
        case .recording(let text):
            return text.isEmpty ? "松开快捷键即可粘贴，Esc 取消" : text
        case .processing:
            return VoiceInputPreferences.aiCorrectionEnabled
                ? "正在使用 AI 整理文字，失败时会自动使用原文"
                : "识别最后一段语音并恢复原应用"
        case .success(let text):
            return text
        case .failed(let message):
            return message
        }
    }
}
#endif
