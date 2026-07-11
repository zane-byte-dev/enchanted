//
//  RemovableImage.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 17/02/2024.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RemovableImage: View {
    var image: Image
    var onClick: () -> ()
    var height: Double = 80
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ImageThumbnail(image: image, size: height)

            Button(action: onClick) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.82)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("移除图片")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

/// A compact, predictable image attachment presentation. Thumbnails always
/// crop from the center while the preview keeps the original aspect ratio.
struct ImageThumbnail: View {
    let image: Image
    var size: CGFloat = 80
    @State private var isPreviewPresented = false

    var body: some View {
        Button {
            isPreviewPresented = true
        } label: {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点击查看大图")
        .sheet(isPresented: $isPreviewPresented) {
            ImagePreviewView(
                image: image,
                onClose: { isPreviewPresented = false }
            )
        }
    }
}

private struct ImagePreviewView: View {
    let image: Image
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            image
                .resizable()
                .scaledToFit()
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .padding(16)
            .keyboardShortcut(.cancelAction)
            .help("关闭")
        }
#if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        .background(ImagePreviewWindowSizer())
#endif
    }
}

#if os(macOS)
/// SwiftUI sizes sheets from their content by default. Match the sheet to its
/// parent window so image inspection uses the whole Enchanted content area.
private struct ImagePreviewWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PreviewSizingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PreviewSizingView)?.resizePreviewWindow()
    }

    private final class PreviewSizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizePreviewWindow()
        }

        func resizePreviewWindow() {
            DispatchQueue.main.async { [weak self] in
                guard
                    let previewWindow = self?.window,
                    let parentWindow = previewWindow.sheetParent
                else { return }

                previewWindow.setContentSize(parentWindow.contentLayoutRect.size)
            }
        }
    }
}
#endif

#Preview {
    RemovableImage(image: Image(systemName: "star"), onClick: {})
}
