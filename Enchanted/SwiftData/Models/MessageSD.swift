//
//  ConversationSD.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData

@Model
final class MessageSD: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()

    var content: String

    /// Parsed `<think>…</think>` split of `content`, memoized per message id
    /// (validated against the current `content`). SwiftUI accesses the derived
    /// values below many times per layout pass; without this each access
    /// re-scanned the whole string several times.
    private var thinkParse: ThinkParse {
        let key = id.uuidString as NSString
        if let cached = MessageSD.cacheStorage.thinkParses.object(forKey: key), cached.source == content {
            return cached.parse
        }
        let parse = ThinkParse(content)
        MessageSD.cacheStorage.thinkParses.setObject(
            CachedThinkParse(source: content, parse: parse),
            forKey: key
        )
        return parse
    }

    var think: String? { thinkParse.think }
    var hasThink: Bool { thinkParse.hasThink }
    var thinkComplete: Bool { thinkParse.complete }
    var realContent: String? { thinkParse.realContent }

    var role: String
    /// Structured render blocks (text/thinking/tool) as JSON. nil for legacy
    /// messages, which fall back to `content` markdown rendering.
    var blocksJSON: String?
    var done: Bool = false
    var error: Bool = false
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var image: Data?

    /// Backward-compatible image list. Older rows store one raw JPEG in
    /// `image`; newer multi-image rows store a small versioned envelope in the
    /// same column so no SwiftData schema migration is required.
    @Transient var imageItems: [Data] {
        guard let image else { return [] }
        if let envelope = try? JSONDecoder().decode(StoredImages.self, from: image),
           envelope.version == 1,
           !envelope.items.isEmpty {
            return envelope.items
        }
        return [image]
    }
    
    @Relationship var conversation: ConversationSD?
        
    
    init(content: String, role: String, done: Bool = false, error: Bool = false, image: Data? = nil) {
        self.content = content
        self.role = role
        self.done = done
        self.error = error
        self.conversation = conversation
        self.image = image
    }

    static func storeImages(_ items: [Data]) -> Data? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items[0] }
        return try? JSONEncoder().encode(StoredImages(version: 1, items: items))
    }

    private struct StoredImages: Codable {
        let version: Int
        let items: [Data]
    }

    @Transient var model: String {
        conversation?.model?.name ?? ""
    }

    /// Decoded render blocks, or empty if none.
    //
    // `blocksJSON` can be megabytes for busy turns (whole-file `read` results
    // were historically embedded), and SwiftUI evaluates this `@Transient`
    // property many times per layout pass — decoding every time caused the
    // long white-screen on return from another app. We memoize the decoded
    // value in a process-wide `NSCache` keyed by message id, validating the
    // cached JSON string so updates to `blocksJSON` invalidate it.
    @Transient var renderBlocks: [MessageBlock] {
        guard let json = blocksJSON, let data = json.data(using: .utf8) else { return [] }
        let key = id.uuidString as NSString
        if let cached = MessageSD.cacheStorage.renderBlocks.object(forKey: key), cached.json == json {
            return cached.blocks
        }
        let blocks = (try? JSONDecoder().decode([MessageBlock].self, from: data)) ?? []
        MessageSD.cacheStorage.renderBlocks.setObject(
            MessageSD.CachedBlocks(json: json, blocks: blocks),
            forKey: key
        )
        return blocks
    }
}

extension MessageSD {
    /// Process-wide cache for `renderBlocks` (see its doc comment). Held by
    /// the type rather than the instance because `@Transient` computed
    /// properties can't carry stored state.
    private final class CacheStorage: @unchecked Sendable {
        let renderBlocks = NSCache<NSString, CachedBlocks>()
        let thinkParses = NSCache<NSString, CachedThinkParse>()

        init() {
            // Bound by count rather than bytes; entries are small metadata.
            renderBlocks.countLimit = 512
            thinkParses.countLimit = 512
        }
    }

    private static let cacheStorage = CacheStorage()

    final class CachedBlocks {
        let json: String
        let blocks: [MessageBlock]
        init(json: String, blocks: [MessageBlock]) {
            self.json = json
            self.blocks = blocks
        }
    }

    /// Process-wide cache for the `<think>` parse (see `thinkParse`).
    fileprivate final class CachedThinkParse {
        let source: String
        let parse: ThinkParse
        init(source: String, parse: ThinkParse) {
            self.source = source
            self.parse = parse
        }
    }

    static let sample: [MessageSD] = [
        .init(content: "How many quarks there are in SM?", role: "user"),
        .init(content: "There are 6 quarks in SM, each of them has an antiparticle and colour.", role: "assistant"),
        .init(content: "How elementary particle is defined in mathematics?", role: "user"),
        .init(content: "Elementary particle is defined as an irreducible representation of the poincase group.", role: "assistant")
    ]
}

// SwiftData models cross the ModelActor boundary throughout the existing data
// layer. Keep the explicit audited conformance until that layer is migrated to
// immutable DTOs under Swift 6 strict concurrency.
extension MessageSD: @unchecked Sendable {}

/// Result of splitting a message's `content` around `<think>…</think>`.
/// Computed once per `content` change and cached (see `MessageSD.thinkParse`).
struct ThinkParse {
    let hasThink: Bool
    let complete: Bool
    let think: String?
    let realContent: String?

    init(_ content: String) {
        guard content.contains("<think>") else {
            hasThink = false
            complete = false
            think = nil
            realContent = content
            return
        }
        hasThink = true
        if let close = content.range(of: "</think>") {
            complete = true
            think = String(content[content.startIndex..<close.lowerBound])
                .replacingOccurrences(of: "<think>", with: "")
            realContent = String(content[close.upperBound...])
        } else {
            complete = false
            think = content.replacingOccurrences(of: "<think>", with: "")
            realContent = nil
        }
    }
}
