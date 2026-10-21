import Foundation
import XCTest

@testable import SkillDeck

final class QoderSkillUsageServiceTests: XCTestCase {
    func testScanCountsSystemActivationMessagesOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("SkillDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            try makeSystemEvent(timestamp: "2026-10-21T05:06:18.458Z", content: "Skill **skilldeck** activated."),
            try makeSystemEvent(timestamp: "2026-10-21T05:07:18.458Z", content: "Skill **gzh-design** activated."),
            try makeSystemEvent(timestamp: "2026-10-21T05:08:18.458Z", content: "Skill **skilldeck** activated."),
            try makeUserEvent(content: "<command-name>/skilldeck</command-name>"),
            try makeUserEvent(content: "Base directory for this skill: /Users/test/.agents/skills/skilldeck"),
            try makeSystemEvent(timestamp: "2026-10-21T05:09:18.458Z", content: "Something else"),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await QoderSkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["quit"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T05:08:18.458Z")
        )
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckQoderMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await QoderSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func makeSystemEvent(timestamp: String, content: String) throws -> String {
        try jsonLine([
            "type": "system",
            "subtype": "informational",
            "timestamp": timestamp,
            "content": content,
        ])
    }

    private func makeUserEvent(content: String) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": "2026-10-21T05:06:18.328Z",
            "message": [
                "role": "user",
                "content": content,
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
                .appendingPathComponent("SkillDeckQoderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
