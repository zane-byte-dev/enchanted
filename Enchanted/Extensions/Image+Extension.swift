//
//  Image+Extension.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 27/05/2024.
//

import SwiftUI

#if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
extension Image {
    private final class DecodedImageCache: @unchecked Sendable {
        let storage = NSCache<NSString, UIImage>()

        init() {
            storage.countLimit = 128
            storage.totalCostLimit = 32 * 1024 * 1024
        }
    }

    private static let decodedImageCache = DecodedImageCache()

    init?(data: Data) {
        guard let uiImage = UIImage(data: data) else { return nil }
        self.init(uiImage: uiImage)
    }

    static func cached(data: Data, key: String) -> Image? {
        let cacheKey = key as NSString
        if let image = decodedImageCache.storage.object(forKey: cacheKey) {
            return Image(uiImage: image)
        }
        guard let image = UIImage(data: data) else { return nil }
        decodedImageCache.storage.setObject(image, forKey: cacheKey, cost: data.count)
        return Image(uiImage: image)
    }
}
#elseif os(macOS)
extension Image {
    private final class DecodedImageCache: @unchecked Sendable {
        let storage = NSCache<NSString, NSImage>()

        init() {
            storage.countLimit = 128
            storage.totalCostLimit = 32 * 1024 * 1024
        }
    }

    private static let decodedImageCache = DecodedImageCache()

    init?(data: Data) {
        guard let nsImage = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImage)
    }

    static func cached(data: Data, key: String) -> Image? {
        let cacheKey = key as NSString
        if let image = decodedImageCache.storage.object(forKey: cacheKey) {
            return Image(nsImage: image)
        }
        guard let image = NSImage(data: data) else { return nil }
        decodedImageCache.storage.setObject(image, forKey: cacheKey, cost: data.count)
        return Image(nsImage: image)
    }
}
#endif
