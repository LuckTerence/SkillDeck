import Foundation
import XCTest

@testable import SkillDeck

final class ClaudeCodeSkillUsageServiceTests: XCTestCase {
    func testScanCountsSkillExpansionsExactlyOnce() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            // Slash-command record: not an expansion and must not be counted.
            try userString(
                timestamp: "2026-10-21T09:00:00.000Z",
                content: "<command-name>/gzh-design</command-name><command-message>gzh-design</command-message>"
            ),
            // The expanded prompt is the actual, successful skill load.
            try userString(
                timestamp: "2026-10-21T09:00:00.100Z",
                content: "Base directory for this skill: /Users/test/.claude/skills/gzh-design\n\n# GZH Design"
            ),
            // Model-invoked skill: tool_use alone is not evidence of success.
            try jsonLine([
                "type": "assistant",
                "timestamp": "2026-10-21T09:01:00.000Z",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Skill",
                        "input": ["skill": "pdf"],
                    ]],
                ],
            ]),
            // A failed Skill call produces no expansion.
            try userString(
                timestamp: "2026-10-21T09:01:00.100Z",
                content: "Unknown skill: ghost"
            ),
            // The success result text is intentionally ignored; the expansion below is counted.
            try userBlocks(
                timestamp: "2026-10-21T09:01:00.200Z",
                blocks: [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": "Launching skill: pdf",
                    "is_error": false,
                ]]
            ),
            // Body on the same line: the path must stop at the two-space separator.
            try userString(
                timestamp: "2026-10-21T09:01:00.300Z",
                content: "Base directory for this skill: /Users/test/.claude/skills/pdf  # PDF"
            ),
            // Newer transcripts may store the expansion as text blocks.
            try userBlocks(
                timestamp: "2026-10-21T09:02:00.000Z",
                blocks: [[
                    "type": "text",
                    "text": "Base directory for this skill: /Users/test/.claude/skills/session-export\n\n# Session Export",
                ]]
            ),
            // Tool output containing the marker must not be counted.
            try userBlocks(
                timestamp: "2026-10-21T09:03:00.000Z",
                blocks: [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_2",
                    "content": "Base directory for this skill: /Users/test/.claude/skills/not-a-real-use",
                    "is_error": false,
                ]]
            ),
            // Built-in command has no skill expansion.
            try userString(
                timestamp: "2026-10-21T09:04:00.000Z",
                content: "<command-name>/model</command-name><command-message>model</command-message>"
            ),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await ClaudeCodeSkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["pdf"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["session-export"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["ghost"])
        XCTAssertNil(result.records["model"])
        XCTAssertNil(result.records["not-a-real-use"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:00:00.100Z")
        )
        // Must come from the expansion, not from the ignored "Launching skill" result.
        XCTAssertEqual(
            result.records["pdf"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:01:00.300Z")
        )
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckClaudeCodeMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await ClaudeCodeSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func userString(timestamp: String, content: String) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": content,
            ],
        ])
    }

    private func userBlocks(timestamp: String, blocks: [[String: Any]]) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": blocks,
            ],
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
                .appendingPathComponent("SkillDeckClaudeCodeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
