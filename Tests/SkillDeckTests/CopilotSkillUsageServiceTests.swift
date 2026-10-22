import Foundation
import XCTest

@testable import SkillDeck

final class CopilotSkillUsageServiceTests: XCTestCase {
    func testScanCountsSkillInvokedEventsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let session = fixture.root.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let lines = [
            try skillInvoked(
                timestamp: "2026-10-21T09:00:00.123Z",
                name: "skilldeck",
                path: "/Users/test/.copilot/skills/skilldeck/SKILL.md"
            ),
            // The directory name identifies the skill in SkillDeck, even when the
            // frontmatter name differs from the folder name.
            try skillInvoked(
                timestamp: "2026-10-21T09:01:00.123Z",
                name: "Display Name",
                path: "/Users/test/.agents/skills/gzh-design/SKILL.md"
            ),
            // Older or plugin events may omit the path; the name is a safe fallback.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:00.123Z",
                name: "pdf",
                path: nil
            ),
            // A valid path wins even when the frontmatter name is empty.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:30.123Z",
                name: "",
                path: "/Users/test/.agents/skills/path-only/SKILL.md"
            ),
            // A path that is not a SKILL.md falls back to a non-empty name.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:45.123Z",
                name: "fallback-skill",
                path: "/Users/test/notes/README.md"
            ),
            // Other event types mentioning the word "skill.invoked" must not count.
            try jsonLine([
                "type": "user.message",
                "timestamp": "2026-10-21T09:03:00.123Z",
                "data": ["content": "What does skill.invoked mean?"],
            ]),
            try jsonLine([
                "type": "tool.execution_start",
                "timestamp": "2026-10-21T09:03:30.123Z",
                "data": ["toolName": "skill", "arguments": ["name": "ghost"]],
            ]),
            // Missing data, empty name/path, and malformed lines are ignored.
            try jsonLine([
                "type": "skill.invoked",
                "timestamp": "2026-10-21T09:04:00.123Z",
            ]),
            try skillInvoked(
                timestamp: "2026-10-21T09:04:30.123Z",
                name: "",
                path: ""
            ),
            // Same skill invoked again later: lastDetectedAt must keep the newest timestamp.
            try skillInvoked(
                timestamp: "2026-10-21T09:05:00.123Z",
                name: "skilldeck",
                path: "/Users/test/.copilot/skills/skilldeck/SKILL.md"
            ),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: session.appendingPathComponent("events.jsonl"))

        let result = await CopilotSkillUsageService(
            historyDirectories: [fixture.root],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["pdf"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["path-only"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["fallback-skill"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records.count, 5)
        XCTAssertNil(result.records["Display Name"])
        XCTAssertNil(result.records["ghost"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:05:00.123Z")
        )
    }

    func testDefaultProviderFactoryIncludesCopilotCLI() {
        let providers = SkillUsageProviderFactory.makeDefaultProviders()

        XCTAssertTrue(providers.contains { $0.agentType == .copilotCLI })
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckCopilotMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await CopilotSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func skillInvoked(
        timestamp: String,
        name: String,
        path: String?
    ) throws -> String {
        var data: [String: Any] = ["name": name]
        if let path {
            data["path"] = path
        }
        return try jsonLine([
            "type": "skill.invoked",
            "timestamp": timestamp,
            "data": data,
        ])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeJSONL(_ lines: [String], to url: URL) throws {
        let contents = lines.joined(separator: "\n") + "\n"
        try XCTUnwrap(contents.data(using: .utf8)).write(to: url, options: .atomic)
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckCopilotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
