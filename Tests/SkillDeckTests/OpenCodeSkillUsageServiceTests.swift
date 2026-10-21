import Darwin
import Foundation
import SQLite3
import XCTest

@testable import SkillDeck

final class OpenCodeSkillUsageServiceTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func testScanCountsCompletedSkillPartsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try makeDatabase(at: databaseURL, rows: [
            Row(id: "p1", tool: "skill", skill: "web-access", status: "completed", timestamp: 1_790_000_000_000),
            Row(id: "p2", tool: "skill", skill: "web-access", status: "error", timestamp: 1_790_000_100_000),
            Row(id: "p3", tool: "skill", skill: "gzh-design", status: "completed", timestamp: 1_790_000_200_000),
            Row(id: "p4", tool: "bash", skill: "ignored", status: "completed", timestamp: 1_790_000_300_000),
        ])

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["web-access"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["ignored"])
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_200)
        )
    }

    /// OpenCode 2.x stores skill uses in `session_message`; migrated `part` rows must not double count.
    func testScanCountsSessionMessageToolsAndUserSkillMentions() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try makeSessionDatabase(at: databaseURL, messages: [
            SessionMessage(
                id: "a1",
                type: "assistant",
                timestamp: 1_790_000_000_000,
                data: [
                    "content": [[
                        "type": "tool",
                        "name": "skill",
                        "state": [
                            "status": "completed",
                            "input": ["name": "web-access"],
                        ],
                    ]],
                ]
            ),
            SessionMessage(
                id: "a2",
                type: "assistant",
                timestamp: 1_790_000_100_000,
                data: [
                    "content": [[
                        "type": "tool",
                        "name": "skill",
                        "state": [
                            "status": "error",
                            "input": ["name": "web-access"],
                        ],
                    ]],
                ]
            ),
            SessionMessage(
                id: "a3",
                type: "assistant",
                timestamp: 1_790_000_200_000,
                data: [
                    "content": [[
                        "type": "tool",
                        "name": "bash",
                        "state": [
                            "status": "completed",
                            "input": ["name": "ignored"],
                        ],
                    ]],
                ]
            ),
            SessionMessage(
                id: "u1",
                type: "user",
                timestamp: 1_790_000_300_000,
                data: [
                    "skills": [
                        ["id": "skilldeck", "name": "skilldeck"],
                        ["id": "skilldeck", "name": "skilldeck"],
                    ],
                ]
            ),
            SessionMessage(
                id: "u2",
                type: "user",
                timestamp: 1_790_000_400_000,
                data: [
                    "text": "skills without an attached skill are just text",
                ]
            ),
        ], legacyRows: [
            Row(
                id: "p1",
                tool: "skill",
                skill: "legacy-only",
                status: "completed",
                timestamp: 1_790_000_500_000
            ),
        ])

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["web-access"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 1)
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_300)
        )
        XCTAssertNil(result.records["ignored"])
        XCTAssertNil(result.records["legacy-only"])
    }

    func testScanReturnsNoCoverageWhenDatabaseIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckOpenCodeMissing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("opencode.db")

        let result = await OpenCodeSkillUsageService(databaseURL: missing).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    /// An existing but corrupt database is a read failure, not "no history".
    func testScanReportsUnreadableDatabaseAsFailure() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try "not a sqlite database".write(to: databaseURL, atomically: true, encoding: .utf8)

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    /// An unreadable parent must not be mistaken for a missing database.
    func testScanReportsInaccessibleDatabaseAsFailure() async throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let agentDirectory = fixture.root.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        let databaseURL = agentDirectory.appendingPathComponent("opencode.db")
        try "unused".write(to: databaseURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: agentDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: agentDirectory.path
            )
        }

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    private struct Row {
        let id: String
        let tool: String
        let skill: String
        let status: String
        let timestamp: Int64
    }

    private struct SessionMessage {
        let id: String
        let type: String
        let timestamp: Int64
        let data: [String: Any]
    }

    private func makeDatabase(at url: URL, rows: [Row]) throws {
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE part (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            in: database
        )
        try insertLegacyRows(rows, into: database)
    }

    private func makeSessionDatabase(
        at url: URL,
        messages: [SessionMessage],
        legacyRows: [Row]
    ) throws {
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE part (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                type TEXT NOT NULL,
                seq INTEGER NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            in: database
        )
        try insertLegacyRows(legacyRows, into: database)

        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
        VALUES (?, 'session', ?, 0, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 5)
        }
        defer { sqlite3_finalize(statement) }

        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message.data, options: [.sortedKeys])
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (message.id as NSString).utf8String, -1, Self.transient)
            sqlite3_bind_text(statement, 2, (message.type as NSString).utf8String, -1, Self.transient)
            sqlite3_bind_int64(statement, 3, message.timestamp)
            sqlite3_bind_int64(statement, 4, message.timestamp)
            sqlite3_bind_text(statement, 5, (json as NSString).utf8String, -1, Self.transient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 6)
            }
        }
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 1)
        }
        return database
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 2)
        }
    }

    private func insertLegacyRows(_ rows: [Row], into database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES (?, '', '', ?, ?, ?);
        """
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            let payload: [String: Any] = [
                "type": "tool",
                "tool": row.tool,
                "state": [
                    "status": row.status,
                    "input": ["name": row.skill],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (row.id as NSString).utf8String, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, row.timestamp)
            sqlite3_bind_int64(statement, 3, row.timestamp)
            sqlite3_bind_text(statement, 4, (json as NSString).utf8String, -1, Self.transient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 4)
            }
        }
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
