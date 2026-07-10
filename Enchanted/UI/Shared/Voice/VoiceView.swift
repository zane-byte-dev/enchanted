//
//  ConversationView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 26/05/2024.
//

import SwiftUI

struct VoiceView: View {
#if os(macOS)
    @ObservedObject private var voiceInput = VoiceInputCoordinator.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: voiceInput.state.isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: voiceInput.state.isActive)

            VStack(spacing: 8) {
                Text("随处说话，直接输入")
                    .font(.system(size: 24, weight: .semibold))
                Text("按住全局语音快捷键开始录音，松开后自动粘贴到原应用。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button(voiceInput.state.isActive ? "结束并粘贴" : "测试语音输入") {
                voiceInput.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(voiceInput.state == .processing)

            if !voiceInput.lastTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("上次识别")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if voiceInput.lastUsedAI {
                            Label("AI 已整理", systemImage: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(voiceInput.lastTranscript)
                        .font(.body)
                        .textSelection(.enabled)
                    if let warning = voiceInput.lastProcessingWarning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
        .padding(32)
    }
#else
    var body: some View {
        ContentUnavailableView("语音输入", systemImage: "waveform", description: Text("新的语音输入目前支持 macOS。"))
    }
#endif
}

#Preview {
    VoiceView()
}
