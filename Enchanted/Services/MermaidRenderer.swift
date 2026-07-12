//
//  MermaidRenderer.swift
//  Enchanted
//
//  Offline, process-wide Mermaid renderer. The hidden WKWebView is kept out of
//  the SwiftUI tree so completed diagrams can be displayed as ordinary images.
//

import Foundation
import WebKit

enum MermaidRendererError: LocalizedError {
    case resourceMissing
    case invalidResult(String)
    case rendererReleased

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            return "Mermaid renderer resources are missing."
        case .invalidResult(let reason):
            return "Mermaid returned an invalid SVG: \(reason)"
        case .rendererReleased:
            return "Mermaid renderer is unavailable."
        }
    }
}

enum MermaidSVGValidator {
    static func isSafe(_ svg: String) -> Bool {
        rejectionReason(for: svg) == nil
    }

    static func rejectionReason(for svg: String) -> String? {
        guard let data = svg.data(using: .utf8) else { return "invalid UTF-8" }
        let delegate = MermaidSVGValidationDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if !parsed {
            return parser.parserError?.localizedDescription ?? "malformed XML"
        }
        if !delegate.sawRootSVG { return "missing SVG root" }
        if let reason = delegate.unsafeReason { return reason }
        return nil
    }
}

private final class MermaidSVGValidationDelegate: NSObject, XMLParserDelegate {
    private(set) var sawRootSVG = false
    private(set) var unsafeReason: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let element = elementName.lowercased()
        if !sawRootSVG { sawRootSVG = element == "svg" }
        if ["script", "iframe", "object", "embed"].contains(element) {
            unsafeReason = "active element: \(element)"
        }

        for (rawName, rawValue) in attributeDict {
            let name = rawName.lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name.hasPrefix("on") {
                unsafeReason = "event handler attribute: \(name)"
            }
            if name == "href" || name.hasSuffix(":href") || name == "src" {
                let isLocalReference = value.hasPrefix("#")
                let isRasterData = [
                    "data:image/png;base64,",
                    "data:image/jpeg;base64,",
                    "data:image/webp;base64,",
                    "data:image/gif;base64,"
                ].contains(where: value.hasPrefix)
                if !isLocalReference && !isRasterData {
                    unsafeReason = "external \(name): \(value.prefix(80))"
                }
            }
            inspectText(value)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        inspectText(string.lowercased())
    }

    private func inspectText(_ value: String) {
        if value.contains("javascript:")
            || value.contains("@import")
            || value.contains("url(http:")
            || value.contains("url(https:")
            || value.contains("url(//")
            || value.contains("url(file:") {
            unsafeReason = "active CSS or JavaScript content"
        }
    }
}

@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    private let cache = NSCache<NSString, NSString>()
    private var webView: WKWebView?
    private var isReady = false
    private var loadError: Error?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var renderTail: Task<Void, Never>?

    private override init() {
        super.init()
        cache.countLimit = 128
        cache.totalCostLimit = 12 * 1024 * 1024
    }

    func render(source: String, darkMode: Bool) async throws -> String {
        let key = "\(darkMode ? "dark" : "light")|\(source)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }

        // Mermaid has mutable global configuration. Chaining jobs prevents
        // simultaneous calls from changing each other's theme/configuration.
        let previous = renderTail
        let operation = Task<String, Error> { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { throw MermaidRendererError.rendererReleased }
            let svg = try await self.renderNow(source: source, darkMode: darkMode)
            self.cache.setObject(svg as NSString, forKey: key, cost: svg.utf8.count)
            return svg
        }
        renderTail = Task { _ = await operation.result }
        return try await operation.value
    }

    private func renderNow(source: String, darkMode: Bool) async throws -> String {
        try await ensureLoaded()
        guard let webView else { throw MermaidRendererError.rendererReleased }

        let value = try await webView.callAsyncJavaScript(
            "return await window.renderMermaid(source, identifier, darkMode);",
            arguments: [
                "source": source,
                "identifier": "mox-mermaid-\(UUID().uuidString)",
                "darkMode": darkMode
            ],
            in: nil,
            contentWorld: .page
        )
        guard let svg = value as? String, svg.contains("<svg") else {
            throw MermaidRendererError.invalidResult("missing SVG output")
        }
        if let reason = MermaidSVGValidator.rejectionReason(for: svg) {
            throw MermaidRendererError.invalidResult(reason)
        }
        return svg
    }

    private func ensureLoaded() async throws {
        if isReady { return }
        if let loadError { throw loadError }

        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView

            guard let pageURL = Bundle.main.url(
                forResource: "mermaid-renderer",
                withExtension: "html"
            ) else {
                let error = MermaidRendererError.resourceMissing
                loadError = error
                throw error
            }
            webView.loadFileURL(
                pageURL,
                allowingReadAccessTo: pageURL.deletingLastPathComponent()
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            loadWaiters.append(continuation)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(["file", "about"].contains(scheme) ? .allow : .cancel)
    }

    private func finishLoading(with error: Error) {
        loadError = error
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }
}
