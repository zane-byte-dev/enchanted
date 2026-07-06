//
//  InputFields_macOS.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

#if os(macOS) || os(visionOS)
import SwiftUI

struct InputFieldsView: View {
    @Binding var message: String
    var conversationState: ConversationState
    var onStopGenerateTap: @MainActor () -> Void
    var selectedModel: LanguageModelSD?
    var modelsList: [LanguageModelSD] = []
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> () = { _ in }
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ image: Image?, _ trimmingMessageId: String?) -> ()
    @Binding var editMessage: MessageSD?
    @State var isRecording = false
    
    @State private var selectedImage: Image?
    @State private var fileDropActive: Bool = false
    @State private var fileSelectingActive: Bool = false
    @FocusState private var isFocusedInput: Bool
    
    @MainActor private func sendMessage() {
        guard let selectedModel = selectedModel else { return }
        
        onSendMessageTap(
            message,
            selectedModel,
            selectedImage,
            editMessage?.id.uuidString
        )
        withAnimation {
            isRecording = false
            isFocusedInput = false
            editMessage = nil
            selectedImage = nil
            message = ""
        }
    }
    
    private func updateSelectedImage(_ image: Image) {
        selectedImage = image
    }
    
#if os(macOS)
    var hotkeys: [HotkeyCombination] {
        [
            HotkeyCombination(keyBase: [.command], key: .kVK_ANSI_V) {
                if let nsImage = Clipboard.shared.getImage() {
                    let image = Image(nsImage: nsImage)
                    updateSelectedImage(image)
                }
            }
        ]
    }
#endif
    
    @ViewBuilder
    private var sendButton: some View {
        switch conversationState {
        case .loading:
            Button(action: onStopGenerateTap) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        default:
            Button(action: { Task { sendMessage() } }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(message.isEmpty ? Color.gray : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(message.isEmpty)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = selectedImage {
                RemovableImage(
                    image: image,
                    onClick: {selectedImage = nil},
                    height: 70
                )
                .padding(.horizontal, 6)
            }

            // Text input
            TextField("Message", text: $message.animation(.easeOut(duration: 0.3)), axis: .vertical)
                .focused($isFocusedInput)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .lineLimit(1...12)
                .textFieldStyle(.plain)
#if os(macOS)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        message += "\n"
                    } else {
                        sendMessage()
                    }
                }
#endif
                .allowsHitTesting(!fileDropActive)
#if os(macOS)
                .addCustomHotkeys(hotkeys)
#endif

            // Bottom control row (Codex-style)
            HStack(spacing: 10) {
                // Attach image
                SimpleFloatingButton(systemImage: "plus", onClick: { fileSelectingActive.toggle() })
                    .showIf(selectedModel?.supportsImages ?? false)
                    .fileImporter(isPresented: $fileSelectingActive,
                                  allowedContentTypes: [.png, .jpeg, .tiff],
                                  onCompletion: { result in
                        switch result {
                        case .success(let url):
                            guard url.startAccessingSecurityScopedResource() else { return }
                            if let imageData = try? Data(contentsOf: url) {
                                selectedImage = Image(data: imageData)
                            }
                            url.stopAccessingSecurityScopedResource()
                        case .failure(let error):
                            print(error)
                        }
                    })

                // Model selector
                ModelSelectorView(
                    modelsList: modelsList,
                    selectedModel: selectedModel,
                    onSelectModel: onSelectModel
                )
                .font(.system(size: 12))

                // Reasoning level
                ThinkingLevelMenu()

                Spacer()

                RecordingView(isRecording: $isRecording.animation()) { transcription in
                    withAnimation(.easeIn(duration: 0.3)) {
                        self.message = transcription
                    }
                }

                sendButton
            }
        }
        .transition(.slide)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    Color.gray2Custom,
                    style: StrokeStyle(lineWidth: 1)
                )
        )
        .overlay {
            if fileDropActive {
                DragAndDrop(cornerRadius: 10)
            }
        }
        .animation(.default, value: fileDropActive)
        .onDrop(of: [.image], isTargeted: $fileDropActive.animation(), perform: { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if error == nil, let data {
                    selectedImage = Image(data: data)
                }
            }
            
            return true
        })
        .contentShape(Rectangle())
        .onTapGesture {
            // allow focusing text area on greater tap area
            isFocusedInput = true
        }
    }
}

/// Codex-style reasoning-level selector (off → xhigh), wired to pi's
/// `set_thinking_level` via UserDefaults("piThinkingLevel").
struct ThinkingLevelMenu: View {
    @AppStorage("piThinkingLevel") private var level: String = "medium"

    private let levels: [(id: String, label: String)] = [
        ("off", "Off"),
        ("minimal", "Minimal"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Max"),
    ]

    private var currentLabel: String {
        levels.first(where: { $0.id == level })?.label ?? "Medium"
    }

    var body: some View {
        Menu {
            ForEach(levels, id: \.id) { item in
                Button(action: { level = item.id }) {
                    HStack {
                        Text(item.label)
                        if item.id == level { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                Text(currentLabel)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

#Preview {
    @State var message = ""
    return InputFieldsView(
        message: $message,
        conversationState: .completed,
        onStopGenerateTap: {},
        onSendMessageTap: {_, _, _, _  in},
        editMessage: .constant(nil)
    )
}
#endif
