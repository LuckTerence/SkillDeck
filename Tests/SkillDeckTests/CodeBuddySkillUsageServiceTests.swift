import Foundation
import XCTest

@testable import SkillDeck

final class CodeBuddySkillUsageServiceTests: XCTestCase {
    func testScanCountsCompletedSkillResultsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            try makeResult(timestamp: 1_790_000_000_000, status: "completed", skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_100_000, status: "completed", skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_200_000, status: "error", skillID: "gzh-design"),
            try makeCall(timestamp: 1_790_000_300_000, skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_400_000, status: "completed", skillID: nil),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await CodeBuddySkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 2)
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_100)
        )
        XCTAssertNil(result.records[""])
    }

    func testScanCountsSkillsInvokedThroughReplSandbox() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let lines = [
            try makeREPLResult(timestamp: 1_790_000_500_000, skillID: "skilldeck"),
            try makeREPLResult(timestamp: 1_790_000_600_000, skillID: nil),
            try makeREPLCall(timestamp: 1_790_000_700_000, skillID: "skilldeck"),
        ]
        try writeJSONL(lines, to: projects.appendingPathComponent("session.jsonl"))

        let result = await CodeBuddySkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 1)
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_500)
        )
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckCodeBuddyMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await CodeBuddySkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func makeResult(timestamp: Int, status: String, skillID: String?) throws -> String {
        let outputText: String
        if let skillID {
            outputText = "Base directory for this skill: /Users/test/.codebuddy/skills/\(skillID)\n# \(skillID)"
        } else {
            outputText = "Operation completed"
        }

        return try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call_result",
            "name": "Skill",
            "callId": UUID().uuidString,
            "status": status,
            "output": [
                "type": "text",
                "text": outputText,
            ],
        ])
    }

    private func makeCall(timestamp: Int, skillID: String) throws -> String {
        try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call",
            "name": "Skill",
            "callId": UUID().uuidString,
            "arguments": "{\"skill\":\"\(skillID)\"}",
        ])
    }

    private func makeREPLResult(timestamp: Int, skillID: String?) throws -> String {
        let result: String
        if let skillID {
            result = "Base directory for this skill: /Users/test/.codebuddy/skills/\(skillID)\n# \(skillID)"
        } else {
            result = "console.log('ok')"
        }
        let outputText = try jsonLine([
            "result": result,
            "stdout": "",
            "stderr": "",
        ])

        return try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call_result",
            "name": "REPL",
            "callId": UUID().uuidString,
            "status": "completed",
            "output": [
                "type": "text",
                "text": outputText,
            ],
        ])
    }

    private func makeREPLCall(timestamp: Int, skillID: String) throws -> String {
        try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call",
            "name": "REPL",
            "callId": UUID().uuidString,
            "arguments": "{\"code\":\"await Skill({ skill: \\\"\(skillID)\\\" })\"}",
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
                .appendingPathComponent("SkillDeckCodeBuddyTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
