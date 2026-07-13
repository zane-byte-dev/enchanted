import XCTest
#if os(macOS)
import AppKit
#endif
@testable import Enchanted

final class CoreWorkflowTests: XCTestCase {
    @MainActor
    func testProjectStorePersistsLayoutSortAndManualOrder() throws {
        let suite = "mox-project-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)

        store.setNavigationLayout(.flat)
        store.setSortOrder(.manual, currentPaths: ["/a", "/b", "/c"])
        store.moveProject("/c", relativeTo: "/b", placeAfter: false, currentPaths: ["/a", "/b", "/c"])
        let first = UUID()
        let second = UUID()
        let third = UUID()
        store.moveConversation(
            third,
            relativeTo: first,
            placeAfter: false,
            in: "/a",
            currentIDs: [first, second, third]
        )

        XCTAssertEqual(store.navigationLayout, .flat)
        XCTAssertEqual(store.sortOrder, .manual)
        XCTAssertEqual(store.manualProjectPaths, ["/a", "/c", "/b"])
        XCTAssertEqual(store.manualConversationRank(third, in: "/a"), 0)
        XCTAssertEqual(store.manualConversationRank(first, in: "/a"), 1)

        let restored = ProjectStore(defaults: defaults)
        XCTAssertEqual(restored.navigationLayout, .flat)
        XCTAssertEqual(restored.sortOrder, .manual)
        XCTAssertEqual(restored.manualProjectPaths, ["/a", "/c", "/b"])
        XCTAssertEqual(restored.manualConversationRank(third, in: "/a"), 0)
        XCTAssertEqual(restored.manualConversationRank(first, in: "/a"), 1)
    }

    func testProjectGroupDefaultsToFiveConversationsAndCanExpand() {
        let conversations = (0..<7).map { ConversationSD(name: "Chat \($0)") }
        let group = ProjectGroup(path: "/tmp/project", conversations: conversations)

        XCTAssertEqual(ProjectGroup.defaultVisibleConversationLimit, 5)
        XCTAssertEqual(group.visibleConversations(isExpanded: false).count, 5)
        XCTAssertEqual(group.hiddenConversationCount, 2)
        XCTAssertEqual(group.visibleConversations(isExpanded: true).count, 7)
        XCTAssertEqual(
            group.visibleConversations(isExpanded: false, selectedID: conversations[6].id).map(\.id),
            conversations.prefix(4).map(\.id) + [conversations[6].id]
        )
    }

    func testPiSessionStatsParsesStatusCardFields() throws {
        let stats = try XCTUnwrap(PiSessionStats([
            "tokens": ["total": 1_234, "input": 1_000, "output": 234],
            "cost": 0.125,
            "contextUsage": ["tokens": 175_229, "contextWindow": 353_000, "percent": 49.64],
        ]))

        XCTAssertEqual(stats.totalTokens, 1_234)
        XCTAssertEqual(stats.inputTokens, 1_000)
        XCTAssertEqual(stats.outputTokens, 234)
        XCTAssertEqual(stats.cost, 0.125, accuracy: 0.0001)
        XCTAssertEqual(stats.contextTokens, 175_229)
        XCTAssertEqual(stats.contextWindow, 353_000)
        XCTAssertEqual(stats.contextPercent, 49.64)
    }

    func testProjectFileSystemReaderSortsFiltersAndRejectsEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env"))
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let visible = ProjectFileSystemReader.listChildren(
            rootPath: root.path,
            relativePath: "",
            includeHidden: false
        )
        XCTAssertNil(visible.error)
        XCTAssertEqual(visible.entries.map(\.name), ["Sources", "README.md"])

        let all = ProjectFileSystemReader.listChildren(
            rootPath: root.path,
            relativePath: "",
            includeHidden: true
        )
        XCTAssertEqual(Set(all.entries.map(\.name)), Set(["Sources", "README.md", ".env"]))
        XCTAssertNil(ProjectFileSystemReader.safeURL(rootPath: root.path, relativePath: "../outside"))
        XCTAssertNil(ProjectFileSystemReader.safeURL(rootPath: root.path, relativePath: "outside-link"))
        XCTAssertNotNil(ProjectFileSystemReader.safeURL(rootPath: root.path, relativePath: "Sources"))
    }

    func testProjectFileSystemReaderTextPreviewRejectsBinaryAndOversize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello\nworld".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data([0x41, 0x00, 0x42]).write(to: root.appendingPathComponent("binary.dat"))
        try Data(repeating: 0x41, count: ProjectFileSystemReader.maximumPreviewBytes + 1)
            .write(to: root.appendingPathComponent("large.txt"))

        XCTAssertEqual(
            ProjectFileSystemReader.readPreview(rootPath: root.path, relativePath: "note.txt"),
            "hello\nworld"
        )
        XCTAssertNil(ProjectFileSystemReader.readPreview(rootPath: root.path, relativePath: "binary.dat"))
        XCTAssertNil(ProjectFileSystemReader.readPreview(rootPath: root.path, relativePath: "large.txt"))
    }

    func testBundledPiExecutableDetectionPrefersExecutableHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-bundle-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Contents/Helpers/pi-node")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
        XCTAssertNil(AgentBackendConfig.bundledPiExecutable(in: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(AgentBackendConfig.bundledPiExecutable(in: root), helper.path)
        XCTAssertEqual(
            AgentBackendConfig.piArgumentPrefix(for: helper.path, in: root),
            [root.appendingPathComponent("Contents/Resources/pi-runtime/packages/coding-agent/dist/cli.js").path]
        )
    }

    func testPiHistoryAuthorityGatesAutomaticContinuation() {
        let matching = ConversationHistorySyncReport(
            localTurns: ["first", "second"],
            piTurns: ["first", "second"]
        )
        XCTAssertEqual(matching.status, .inSync(turns: 2))
        XCTAssertTrue(matching.status.permitsAutomaticContinuation)

        let diverged = ConversationHistorySyncReport(
            localTurns: ["first", "local-only"],
            piTurns: ["first", "pi-only"]
        )
        XCTAssertEqual(diverged.status, .drift(localTurns: 2, piTurns: 2))
        XCTAssertFalse(diverged.status.permitsAutomaticContinuation)
        XCTAssertFalse(ConversationHistorySyncStatus.unavailable.permitsAutomaticContinuation)
        XCTAssertFalse(ConversationHistorySyncStatus.unknown.permitsAutomaticContinuation)
    }

    func testSemanticVersionExtraction() {
        XCTAssertEqual(AgentBackendConfig.semanticVersion(in: "pi 0.80.6"), "0.80.6")
        XCTAssertEqual(AgentBackendConfig.semanticVersion(in: "v1.2.3-beta"), "1.2.3")
        XCTAssertNil(AgentBackendConfig.semanticVersion(in: "unknown"))
    }

    func testSemanticVersionComparison() {
        XCTAssertEqual(AgentBackendConfig.compareVersions("0.80.5", "0.80.6"), .orderedAscending)
        XCTAssertEqual(AgentBackendConfig.compareVersions("0.80.6", "0.80.6"), .orderedSame)
        XCTAssertEqual(AgentBackendConfig.compareVersions("0.81.0", "0.80.6"), .orderedDescending)
        XCTAssertEqual(AgentBackendConfig.compareVersions("1.0", "1.0.0"), .orderedSame)
    }

    func testPlanSnapshotRoundTrip() throws {
        let snapshot = AgentPlanSnapshot(
            explanation: "Ship safely",
            items: [
                AgentPlanItem(step: "Build", status: "in_progress"),
                AgentPlanItem(step: "Verify", status: "pending")
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(AgentPlanSnapshot.self, from: data), snapshot)
    }

    func testRenderBlocksWriteThroughAndDirectAssignmentInvalidation() throws {
        let message = MessageSD(content: "", role: "assistant")
        let streamed: [MessageBlock] = [.thinking("checking"), .text("done")]

        message.setRenderBlocks(streamed)

        XCTAssertNotNil(message.blocksJSON)
        XCTAssertEqual(message.renderBlocks, streamed)

        let replacement: [MessageBlock] = [.text("updated")]
        message.blocksJSON = String(
            data: try JSONEncoder().encode(replacement),
            encoding: .utf8
        )
        XCTAssertEqual(message.renderBlocks, replacement)
    }

    func testPiTranscriptImportIsIdempotentAndMergesAssistantFragments() throws {
        let entries: [[String: Any]] = [
            ["type": "session", "id": "root"],
            [
                "type": "message", "id": "user", "parentId": "root",
                "message": ["role": "user", "content": "Inspect the project"],
            ],
            [
                "type": "message", "id": "assistant-tool", "parentId": "user",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "toolCall", "id": "call-1", "name": "read",
                        "arguments": ["path": "README.md"],
                    ]],
                ],
            ],
            [
                "type": "message", "id": "tool-result", "parentId": "assistant-tool",
                "message": [
                    "role": "toolResult", "toolCallId": "call-1",
                    "content": [["type": "text", "text": "large result"]],
                ],
            ],
            [
                "type": "message", "id": "assistant-text", "parentId": "tool-result",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "Finished"]],
                ],
            ],
        ]
        let lines = try entries.map {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
        // A replayed JSONL line with the same stable id must not create a
        // second visible message.
        let transcript = ConversationStore.parsePiTranscript(
            (lines + [lines.last!]).joined(separator: "\n")
        )

        XCTAssertEqual(transcript.map(\.role), ["user", "assistant"])
        XCTAssertEqual(transcript.last?.content, "Finished")
        XCTAssertEqual(transcript.last?.blocks.count, 2)
        guard case .tool(let tool) = transcript.last?.blocks.first else {
            return XCTFail("Expected the tool fragment to be merged")
        }
        XCTAssertFalse(tool.running)
        XCTAssertNil(tool.resultText, "Read-only tool payloads must stay out of history")
    }

    func testIncrementalMarkdownKeepsOnlyLiveParagraphOutOfCache() {
        let first = IncrementalMarkdownRenderParts.split(
            "Finished **paragraph**.\n\nLive"
        )
        let next = IncrementalMarkdownRenderParts.split(
            "Finished **paragraph**.\n\nLive tokens keep arriving"
        )

        XCTAssertEqual(first.stablePrefix, "Finished **paragraph**.\n\n")
        XCTAssertEqual(first.stablePrefix, next.stablePrefix)
        XCTAssertEqual(next.liveTail, "Live tokens keep arriving")
        XCTAssertEqual(next.stablePrefix + next.liveTail,
                       "Finished **paragraph**.\n\nLive tokens keep arriving")
    }

    func testIncrementalMarkdownDoesNotSplitInsideFencedCode() {
        let openFence = IncrementalMarkdownRenderParts.split(
            "Intro.\n\n```swift\nlet first = 1\n\nlet second = 2"
        )
        XCTAssertEqual(openFence.stablePrefix, "Intro.\n\n")
        XCTAssertEqual(openFence.liveTail, "```swift\nlet first = 1\n\nlet second = 2")

        let closedFence = IncrementalMarkdownRenderParts.split(
            "Intro.\n\n```swift\nlet first = 1\n\nlet second = 2\n```\n\nTail"
        )
        XCTAssertEqual(
            closedFence.stablePrefix,
            "Intro.\n\n```swift\nlet first = 1\n\nlet second = 2\n```\n\n"
        )
        XCTAssertEqual(closedFence.liveTail, "Tail")
    }

    func testFormulaMarkdownParsesInlineAndIgnoresCodeAndEscapedCurrency() {
        let source = "Price is \\$5 and `$ignored$`.\n\nEuler: $e^{i\\pi}+1=0$."
        let segments = FormulaMarkdownParser.parse(source)

        XCTAssertEqual(segments.count, 2)
        guard case .markdown(let ordinary) = segments[0] else {
            return XCTFail("Expected currency and inline code to remain Markdown")
        }
        XCTAssertTrue(ordinary.contains(#"\$5"#))
        XCTAssertTrue(ordinary.contains("`$ignored$`"))

        guard case .inline(let tokens) = segments[1] else {
            return XCTFail("Expected a mixed inline formula paragraph")
        }
        XCTAssertTrue(tokens.contains(.formula(#"e^{i\pi}+1=0"#)))
    }

    func testFormulaMarkdownParsesDisplayMathAndPreservesInvalidInput() {
        let display = FormulaMarkdownParser.parse(
            "Before\n\n$$\n\\int_0^1 x^2 \\, dx\n$$\n\nAfter"
        )
        XCTAssertTrue(display.contains(.display(#"\int_0^1 x^2 \, dx"#)))

        let singleLine = FormulaMarkdownParser.parse("$$E = mc^2$$")
        XCTAssertEqual(singleLine, [.display("E = mc^2")])

        let invalid = FormulaMarkdownParser.parse("Keep $not closed as text")
        XCTAssertEqual(invalid, [.markdown("Keep $not closed as text")])
    }

    func testFormulaMarkdownDoesNotParseInsideFencedCode() {
        let source = "```swift\nlet price = \"$5\"\n// $$notMath$$\n```"
        XCTAssertEqual(FormulaMarkdownParser.parse(source), [.markdown(source)])

        let inlineCode = "Use `$$notMath$$` and `$alsoNotMath$` literally."
        XCTAssertEqual(FormulaMarkdownParser.parse(inlineCode), [.markdown(inlineCode)])
    }

    func testMermaidFenceBecomesDiagramSegment() {
        let source = "Intro\n```mermaid\ngraph TD\n  A[Plan] --> B[Build]\n\n  B --> C[Test]\n```\nTail"
        let segments = FormulaMarkdownParser.parse(source)

        XCTAssertEqual(
            segments,
            [
                .markdown("Intro\n"),
                .mermaid("graph TD\n  A[Plan] --> B[Build]\n\n  B --> C[Test]"),
                .markdown("Tail")
            ]
        )
    }

    func testMermaidRequiresCompleteExactFence() {
        let incomplete = "```mermaid\ngraph TD\n  A --> B"
        XCTAssertEqual(FormulaMarkdownParser.parse(incomplete), [.markdown(incomplete)])

        let ordinary = "```swift\nlet mermaid = true\n```"
        XCTAssertEqual(FormulaMarkdownParser.parse(ordinary), [.markdown(ordinary)])

        let variant = "```mermaid-js\ngraph TD\n  A --> B\n```"
        XCTAssertEqual(FormulaMarkdownParser.parse(variant), [.markdown(variant)])
    }

    func testAgentGuidanceScannerMatchesPiDiscoveryOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-guidance-\(UUID().uuidString)", isDirectory: true)
        let agentDirectory = root.appendingPathComponent("agent-home", isDirectory: true)
        let package = root.appendingPathComponent("packages", isDirectory: true)
        let app = package.appendingPathComponent("app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("global".utf8).write(to: agentDirectory.appendingPathComponent("AGENTS.md"))
        try Data("root wins".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        try Data("package".utf8).write(to: package.appendingPathComponent("CLAUDE.md"))
        try Data("closest".utf8).write(to: app.appendingPathComponent("AGENTS.MD"))

        let snapshot = AgentGuidanceScanner.scan(
            workingDirectory: app.path,
            agentDirectory: agentDirectory.path,
            stopDirectory: root.path
        )

        XCTAssertEqual(
            snapshot.files.map { $0.url.lastPathComponent.lowercased() },
            ["agents.md", "agents.md", "claude.md", "agents.md"]
        )
        XCTAssertEqual(
            snapshot.files.map(\.scope),
            [.global, .ancestor, .ancestor, .workingDirectory]
        )
        XCTAssertEqual(snapshot.files.last?.byteCount, 7)
        XCTAssertTrue(snapshot.unreadablePaths.isEmpty)
    }

    func testUnifiedDiffParserTracksOldAndNewLineNumbers() {
        let diff = """
        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -10,3 +10,4 @@
         context
        -old value
        +new value
        +extra value
         tail
        """
        let lines = UnifiedDiffParser.parse(diff)

        XCTAssertEqual(lines[4].reference, .init(oldLine: 10, newLine: 10))
        XCTAssertEqual(lines[5].kind, .deletion)
        XCTAssertEqual(lines[5].reference, .init(oldLine: 11, newLine: nil))
        XCTAssertEqual(lines[6].kind, .addition)
        XCTAssertEqual(lines[6].reference, .init(oldLine: nil, newLine: 11))
        XCTAssertEqual(lines[7].reference, .init(oldLine: nil, newLine: 12))
        XCTAssertEqual(lines[8].reference, .init(oldLine: 12, newLine: 13))
    }

    func testDiffReviewPromptKeepsPreciseLocations() {
        let comments = [
            DiffReviewComment(
                filePath: "Sources/App.swift",
                reference: .init(oldLine: nil, newLine: 42),
                sourceLine: "+try launch()",
                body: "Please handle the error explicitly."
            ),
            DiffReviewComment(
                filePath: "Sources/Old.swift",
                reference: .init(oldLine: 7, newLine: nil),
                sourceLine: "-legacy()",
                body: "Confirm this removal is safe."
            )
        ]
        let prompt = DiffReviewPrompt.make(comments: comments)

        XCTAssertTrue(prompt.contains("`Sources/App.swift:L42`"))
        XCTAssertTrue(prompt.contains("`Sources/Old.swift:旧 L7`"))
        XCTAssertTrue(prompt.contains("Please handle the error explicitly."))

        let untracked = UnifiedDiffParser.parse("first\nsecond", isUntracked: true)
        XCTAssertEqual(untracked.map(\.reference), [
            .init(oldLine: nil, newLine: 1),
            .init(oldLine: nil, newLine: 2)
        ])
    }

#if os(macOS)
    func testManagedWorktreeCopiesCurrentLocalState() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-worktree-copy-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.name", "Mox Tests"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.email", "mox@example.invalid"], at: root).status, 0)

        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("base\n".utf8).write(to: tracked)
        try Data(".env\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data(".env\n".utf8).write(to: root.appendingPathComponent(".worktreeinclude"))
        XCTAssertEqual(runGit(["add", "."], at: root).status, 0)
        XCTAssertEqual(runGit(["commit", "-qm", "base"], at: root).status, 0)

        try Data("base\nstaged\n".utf8).write(to: tracked)
        XCTAssertEqual(runGit(["add", "tracked.txt"], at: root).status, 0)
        try Data("base\nstaged\nworking\n".utf8).write(to: tracked)
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("LOCAL_TOKEN=test\n".utf8).write(to: root.appendingPathComponent(".env"))

        let worktreePath = try XCTUnwrap(GitWorktree.create(from: root.path, name: "Copy state"))
        let worktree = URL(fileURLWithPath: worktreePath)
        XCTAssertTrue(runGit(["diff", "--cached"], at: worktree).output.contains("staged"))
        XCTAssertTrue(runGit(["diff"], at: worktree).output.contains("working"))
        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent("note.txt"), encoding: .utf8),
            "untracked\n"
        )
        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8),
            "LOCAL_TOKEN=test\n"
        )
        XCTAssertTrue(runGit(["status", "--porcelain"], at: root).output.contains("note.txt"))
        XCTAssertTrue(GitWorktree.isMainWorktree(root.path))
        XCTAssertFalse(GitWorktree.isMainWorktree(worktreePath))
    }

    func testGitHandoffMovesStateBothDirections() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-handoff-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.name", "Mox Tests"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.email", "mox@example.invalid"], at: root).status, 0)
        let file = root.appendingPathComponent("app.txt")
        try Data("base\n".utf8).write(to: file)
        XCTAssertEqual(runGit(["add", "app.txt"], at: root).status, 0)
        XCTAssertEqual(runGit(["commit", "-qm", "base"], at: root).status, 0)

        let worktreePath = try XCTUnwrap(GitWorktree.create(from: root.path, name: "Round trip"))
        let worktree = URL(fileURLWithPath: worktreePath)
        let worktreeFile = worktree.appendingPathComponent("app.txt")
        try Data("base\nstaged\n".utf8).write(to: worktreeFile)
        XCTAssertEqual(runGit(["add", "app.txt"], at: worktree).status, 0)
        try Data("base\nstaged\nworking\n".utf8).write(to: worktreeFile)
        try Data("extra\n".utf8).write(to: worktree.appendingPathComponent("extra.txt"))

        let blocker = root.appendingPathComponent("local-only.txt")
        try Data("do not overwrite\n".utf8).write(to: blocker)
        let toLocal = GitWorktree.handoff(from: worktreePath, to: root.path)
        XCTAssertTrue(toLocal.success, toLocal.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path))
        XCTAssertTrue(runGit(["diff", "--cached"], at: root).output.contains("staged"))
        XCTAssertTrue(runGit(["diff"], at: root).output.contains("working"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("extra.txt").path))
        XCTAssertTrue(runGit(["status", "--porcelain"], at: worktree).output.isEmpty)

        let toWorktree = GitWorktree.handoff(from: root.path, to: worktreePath)
        XCTAssertTrue(toWorktree.success, toWorktree.message)
        XCTAssertTrue(runGit(["diff", "--cached"], at: worktree).output.contains("staged"))
        XCTAssertTrue(runGit(["diff"], at: worktree).output.contains("working"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("extra.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("local-only.txt").path))
        XCTAssertTrue(runGit(["status", "--porcelain"], at: root).output.isEmpty)
    }

    func testGitHandoffConflictRestoresDirtyDestinationAndPreservesSource() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-handoff-conflict-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.name", "Mox Tests"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.email", "mox@example.invalid"], at: root).status, 0)
        let localFile = root.appendingPathComponent("app.txt")
        try Data("base\n".utf8).write(to: localFile)
        XCTAssertEqual(runGit(["add", "app.txt"], at: root).status, 0)
        XCTAssertEqual(runGit(["commit", "-qm", "base"], at: root).status, 0)
        XCTAssertNotNil(GitRepositoryActions.currentBranch(at: root.path))

        let worktreePath = try XCTUnwrap(GitWorktree.create(from: root.path, name: "Conflict"))
        let worktree = URL(fileURLWithPath: worktreePath)
        let worktreeFile = worktree.appendingPathComponent("app.txt")
        try Data("source change\n".utf8).write(to: worktreeFile)
        try Data("destination change\n".utf8).write(to: localFile)
        try Data("keep me\n".utf8).write(to: root.appendingPathComponent("local-note.txt"))

        let sourceStatusBefore = runGit(["status", "--porcelain=v1"], at: worktree).output
        let destinationStatusBefore = runGit(["status", "--porcelain=v1"], at: root).output
        let result = GitWorktree.handoff(from: worktreePath, to: root.path)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("Destination was restored"), result.message)
        XCTAssertTrue(result.message.contains("app.txt"), result.message)
        XCTAssertEqual(try String(contentsOf: worktreeFile, encoding: .utf8), "source change\n")
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), "destination change\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("local-note.txt"), encoding: .utf8),
            "keep me\n"
        )
        XCTAssertEqual(runGit(["status", "--porcelain=v1"], at: worktree).output, sourceStatusBefore)
        XCTAssertEqual(runGit(["status", "--porcelain=v1"], at: root).output, destinationStatusBefore)
    }

    func testGitHandoffMergesDirtyIndexAndWorkingTreeLayers() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-handoff-layers-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.name", "Mox Tests"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.email", "mox@example.invalid"], at: root).status, 0)
        for name in ["source-staged.txt", "source-working.txt", "destination-staged.txt", "destination-working.txt"] {
            try Data("base\n".utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(runGit(["add", "."], at: root).status, 0)
        XCTAssertEqual(runGit(["commit", "-qm", "base"], at: root).status, 0)

        let worktreePath = try XCTUnwrap(GitWorktree.create(from: root.path, name: "Layer merge"))
        let worktree = URL(fileURLWithPath: worktreePath)
        try Data("source staged\n".utf8).write(to: worktree.appendingPathComponent("source-staged.txt"))
        XCTAssertEqual(runGit(["add", "source-staged.txt"], at: worktree).status, 0)
        try Data("source working\n".utf8).write(to: worktree.appendingPathComponent("source-working.txt"))

        try Data("destination staged\n".utf8).write(to: root.appendingPathComponent("destination-staged.txt"))
        XCTAssertEqual(runGit(["add", "destination-staged.txt"], at: root).status, 0)
        try Data("destination working\n".utf8).write(to: root.appendingPathComponent("destination-working.txt"))

        let result = GitWorktree.handoff(from: worktreePath, to: root.path)
        XCTAssertTrue(result.success, result.message)
        let staged = runGit(["diff", "--cached", "--name-only"], at: root).output
        let working = runGit(["diff", "--name-only"], at: root).output
        XCTAssertTrue(staged.contains("source-staged.txt"), staged)
        XCTAssertTrue(staged.contains("destination-staged.txt"), staged)
        XCTAssertTrue(working.contains("source-working.txt"), working)
        XCTAssertTrue(working.contains("destination-working.txt"), working)
        XCTAssertFalse(staged.contains("source-working.txt"), staged)
        XCTAssertFalse(working.contains("source-staged.txt"), working)
        XCTAssertTrue(runGit(["status", "--porcelain"], at: worktree).output.isEmpty)
    }

    func testGitCommitInspectAndPushToLocalRemote() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-publish-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        let remote = container.appendingPathComponent("remote.git", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        XCTAssertEqual(runGit(["init", "--bare", "-q"], at: remote).status, 0)
        XCTAssertEqual(runGit(["config", "user.name", "Mox Tests"], at: root).status, 0)
        XCTAssertEqual(runGit(["config", "user.email", "mox@example.invalid"], at: root).status, 0)

        let file = root.appendingPathComponent("README.md")
        try Data("first\n".utf8).write(to: file)
        XCTAssertEqual(runGit(["add", "README.md"], at: root).status, 0)
        guard case .success(let beforeCommit) = GitRepositoryActions.inspect(at: root.path) else {
            return XCTFail("Expected repository inspection to succeed")
        }
        XCTAssertTrue(beforeCommit.hasStagedChanges)
        XCTAssertTrue(GitRepositoryActions.commit(at: root.path, message: "initial").success)

        XCTAssertEqual(runGit(["remote", "add", "origin", remote.path], at: root).status, 0)
        XCTAssertTrue(GitRepositoryActions.push(at: root.path).success)
        guard case .success(let afterFirstPush) = GitRepositoryActions.inspect(at: root.path) else {
            return XCTFail("Expected upstream after first push")
        }
        XCTAssertNotNil(afterFirstPush.upstream)
        XCTAssertEqual(afterFirstPush.ahead, 0)

        try Data("first\nsecond\n".utf8).write(to: file)
        XCTAssertEqual(runGit(["add", "README.md"], at: root).status, 0)
        XCTAssertTrue(GitRepositoryActions.commit(at: root.path, message: "second").success)
        guard case .success(let ahead) = GitRepositoryActions.inspect(at: root.path) else {
            return XCTFail("Expected repository inspection after second commit")
        }
        XCTAssertEqual(ahead.ahead, 1)
        XCTAssertTrue(GitRepositoryActions.push(at: root.path).success)
        guard case .success(let synced) = GitRepositoryActions.inspect(at: root.path) else {
            return XCTFail("Expected repository inspection after second push")
        }
        XCTAssertEqual(synced.ahead, 0)
        XCTAssertFalse(synced.hasStagedChanges)

        XCTAssertEqual(
            GitRepositoryActions.pullRequestArguments(
                title: "Ship it",
                body: "Details",
                isDraft: true
            ),
            ["pr", "create", "--title", "Ship it", "--body", "Details", "--draft"]
        )

        let fakeBin = container.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeGH = fakeBin.appendingPathComponent("gh")
        try Data("#!/bin/sh\n".utf8).write(to: fakeGH)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGH.path)
        XCTAssertEqual(
            GitRepositoryActions.githubCLIPath(
                environment: ["PATH": fakeBin.path],
                homeDirectory: container.path
            ),
            fakeGH.path
        )
    }

    func testGitHunkStageUnstageAndRevert() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-hunk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertEqual(runGit(["init", "-q"], at: root).status, 0)
        let file = root.appendingPathComponent("sample.txt")
        let originalLines = (1...24).map { "line \($0)" }
        try Data(originalLines.joined(separator: "\n").appending("\n").utf8).write(to: file)
        XCTAssertEqual(runGit(["add", "sample.txt"], at: root).status, 0)
        XCTAssertEqual(
            runGit([
                "-c", "user.name=Mox Tests",
                "-c", "user.email=mox@example.invalid",
                "commit", "-qm", "base"
            ], at: root).status,
            0
        )

        var changedLines = originalLines
        changedLines[1] = "line 2 changed"
        changedLines[21] = "line 22 changed"
        try Data(changedLines.joined(separator: "\n").appending("\n").utf8).write(to: file)

        let initialDiff = runGit(["diff", "--unified=3", "--", "sample.txt"], at: root).output
        let initialHunks = UnifiedDiffParser.hunks(in: initialDiff)
        XCTAssertEqual(initialHunks.count, 2)

        XCTAssertNil(GitHunkMutator.apply(
            .stage,
            repositoryRoot: root.path,
            patch: initialHunks[0].patch
        ))
        let staged = runGit(["diff", "--cached", "--", "sample.txt"], at: root).output
        XCTAssertTrue(staged.contains("line 2 changed"))
        XCTAssertFalse(staged.contains("line 22 changed"))

        let stagedHunk = try XCTUnwrap(UnifiedDiffParser.hunks(in: staged).first)
        XCTAssertNil(GitHunkMutator.apply(
            .unstage,
            repositoryRoot: root.path,
            patch: stagedHunk.patch
        ))
        XCTAssertTrue(runGit(["diff", "--cached", "--", "sample.txt"], at: root).output.isEmpty)

        let remainingHunks = UnifiedDiffParser.hunks(
            in: runGit(["diff", "--unified=3", "--", "sample.txt"], at: root).output
        )
        XCTAssertEqual(remainingHunks.count, 2)
        XCTAssertNil(GitHunkMutator.apply(
            .revert,
            repositoryRoot: root.path,
            patch: remainingHunks[1].patch
        ))
        let fileAfterRevert = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(fileAfterRevert.contains("line 2 changed"))
        XCTAssertFalse(fileAfterRevert.contains("line 22 changed"))
    }

    @MainActor
    func testBundledMermaidRendersOfflineSVG() async throws {
        let svg = try await MermaidRenderer.shared.render(
            source: "graph LR\n  A[Parse] --> B[Render]",
            darkMode: false
        )

        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("Parse"))
        XCTAssertNotNil(NSImage(data: Data(svg.utf8)))
    }

    func testMermaidSVGValidatorRejectsActiveOrExternalContent() {
        let safe = ##"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div><use href="#node"/></div></foreignObject></svg>"##
        XCTAssertTrue(MermaidSVGValidator.isSafe(safe))

        let external = #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/a.png"/></svg>"#
        XCTAssertFalse(MermaidSVGValidator.isSafe(external))

        let active = #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><script>run()</script></foreignObject></svg>"#
        XCTAssertFalse(MermaidSVGValidator.isSafe(active))

        let eventHandler = #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div onload="run()"/></foreignObject></svg>"#
        XCTAssertFalse(MermaidSVGValidator.isSafe(eventHandler))
    }

    private func runGit(_ arguments: [String], at root: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
#endif

    func testArtifactPathClassification() {
        let write = ToolCall(
            callId: "1",
            name: "write",
            argsJSON: #"{"path":"docs/report.pdf","content":"x"}"#
        )
        let read = ToolCall(
            callId: "2",
            name: "read",
            argsJSON: #"{"path":"docs/report.pdf"}"#
        )
        XCTAssertEqual(write.artifactPath, "docs/report.pdf")
        XCTAssertNil(read.artifactPath)
    }

    func testScheduledRunHistoryRoundTrip() throws {
        let record = ScheduledTaskRunRecord(
            id: UUID(),
            launchedAt: Date(timeIntervalSince1970: 123),
            status: "completed",
            conversationID: UUID()
        )
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([ScheduledTaskRunRecord].self, from: data), [record])
    }

    func testPiAssistantErrorExtraction() {
        let payload: [String: Any] = [
            "type": "message_update",
            "assistantMessageEvent": [
                "type": "error",
                "reason": "error",
                "error": [
                    "stopReason": "error",
                    "errorMessage": "Quota exceeded",
                ],
            ],
        ]

        XCTAssertEqual(PiConnector.assistantErrorMessage(in: payload), "Quota exceeded")
    }

    func testPiAssistantAbortIsNotAnError() {
        let payload: [String: Any] = [
            "type": "message_update",
            "assistantMessageEvent": [
                "type": "error",
                "reason": "aborted",
                "error": [
                    "stopReason": "aborted",
                    "errorMessage": "Request aborted",
                ],
            ],
        ]

        XCTAssertNil(PiConnector.assistantErrorMessage(in: payload))
    }
}
