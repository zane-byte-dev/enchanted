import XCTest
@testable import Enchanted

final class CoreWorkflowTests: XCTestCase {
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
}
