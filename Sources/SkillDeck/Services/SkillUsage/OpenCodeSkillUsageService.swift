import Foundation
import SQLite3

/// Recovers skill invocations from OpenCode's local SQLite database.
///
/// OpenCode 2.x writes messages to `session_message`, where a skill use appears either as a
/// completed `skill` tool part or, in newer releases, as a `skills` entry on a user message
/// created by an `@skill` mention. `session_message` also contains migrated history, so it is
/// preferred over the legacy `part` table whenever it has rows; querying both would double count.
/// Legacy 1.x JSON files under `storage/part/` are intentionally ignored because current
/// OpenCode versions no longer write there.
actor OpenCodeSkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .openCode }

    private let databaseURL: URL

    /// Production initializer based on the current macOS user's home directory.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }

    /// Test initializer that points at a temporary SQLite fixture.
    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func scan() -> SkillUsageScanResult {
        switch SkillUsagePathProbe.status(at: databaseURL) {
        case .missing:
            return SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 0
            )
        case .directory, .inaccessible:
            // The path exists but cannot be a readable database, or its parent cannot be
            // inspected. Report a failure instead of claiming there is no history.
            return Self.failure
        case .notDirectory:
            break
        }

        guard let database = openReadOnly() else {
            return Self.failure
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        let rows: [SkillRow]
        if tableExists("session_message", in: database),
           tableHasRows("session_message", in: database) {
            guard let sessionRows = readSessionMessageRows(from: database) else {
                return Self.failure
            }
            rows = sessionRows
        } else if tableExists("part", in: database) {
            guard let legacyRows = readLegacyPartRows(from: database) else {
                return Self.failure
            }
            rows = legacyRows
        } else {
            // The file is a database, but not one this provider understands.
            return Self.failure
        }

        var records: [String: MutableSkillUsageRecord] = [:]
        for row in rows where row.status == "completed" {
            var record = records[row.skillID] ?? MutableSkillUsageRecord()
            record.detectedInvocationCount += 1
            if let timestamp = row.timestamp,
               record.lastDetectedAt == nil || timestamp > record.lastDetectedAt! {
                record.lastDetectedAt = timestamp
            }
            records[row.skillID] = record
        }

        return SkillUsageScanResult(
            records: records.mapValues {
                SkillUsageRecord(
                    detectedInvocationCount: $0.detectedInvocationCount,
                    lastDetectedAt: $0.lastDetectedAt
                )
            },
            scannedLogCount: 1,
            preservedLogCount: 0,
            failedLogCount: 0
        )
    }

    private static let failure = SkillUsageScanResult(
        // Report zero readable coverage so the manager maps this to `.failed` instead of
        // `.available` with "no usage detected".
        records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 1
    )

    private func openReadOnly() -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            // SQLite may allocate a handle even when opening fails; close it to avoid leaking
            // one connection per refresh attempt against a corrupt or unreadable database.
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        return database
    }

    private func tableExists(_ name: String, in database: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func tableHasRows(_ name: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM \(name) LIMIT 1", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func readSessionMessageRows(from database: OpaquePointer) -> [SkillRow]? {
        let sql = """
        SELECT time_created, type, data
        FROM session_message
        WHERE type IN ('assistant', 'user') AND data LIKE '%skill%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SkillRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return rows
            }
            guard step == SQLITE_ROW else {
                return nil
            }
            guard let typeText = sqlite3_column_text(statement, 1),
                  let dataText = sqlite3_column_text(statement, 2) else {
                continue
            }

            let createdAt = sqlite3_column_int64(statement, 0)
            let timestamp = createdAt > 0
                ? Date(timeIntervalSince1970: Double(createdAt) / 1000)
                : nil
            let type = String(cString: typeText)
            let data = String(cString: dataText)

            guard let jsonData = data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                continue
            }

            switch type {
            case "assistant":
                for content in object["content"] as? [[String: Any]] ?? [] {
                    guard content["type"] as? String == "tool",
                          content["name"] as? String == "skill",
                          let state = content["state"] as? [String: Any],
                          state["status"] as? String == "completed",
                          let input = state["input"] as? [String: Any],
                          let skillID = input["name"] as? String,
                          !skillID.isEmpty else {
                        continue
                    }
                    rows.append(SkillRow(
                        skillID: skillID,
                        status: "completed",
                        timestamp: timestamp
                    ))
                }
            case "user":
                guard let skills = object["skills"] as? [[String: Any]] else { continue }
                var seen: Set<String> = []
                for skill in skills {
                    guard let skillID = (skill["id"] as? String) ?? (skill["name"] as? String),
                          !skillID.isEmpty,
                          seen.insert(skillID).inserted else {
                        continue
                    }
                    rows.append(SkillRow(
                        skillID: skillID,
                        status: "completed",
                        timestamp: timestamp
                    ))
                }
            default:
                continue
            }
        }
    }

    private func readLegacyPartRows(from database: OpaquePointer) -> [SkillRow]? {
        let sql = """
        SELECT json_extract(data, '$.state.input.name'),
               json_extract(data, '$.state.status'),
               time_created
        FROM part
        WHERE json_extract(data, '$.tool') = 'skill'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SkillRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return rows
            }
            guard step == SQLITE_ROW else {
                return nil
            }
            guard let nameText = sqlite3_column_text(statement, 0),
                  let statusText = sqlite3_column_text(statement, 1) else {
                continue
            }

            let skillID = String(cString: nameText)
            guard !skillID.isEmpty else { continue }

            let createdAt = sqlite3_column_int64(statement, 2)
            rows.append(SkillRow(
                skillID: skillID,
                status: String(cString: statusText),
                timestamp: createdAt > 0
                    ? Date(timeIntervalSince1970: Double(createdAt) / 1000)
                    : nil
            ))
        }
    }

    private struct SkillRow {
        let skillID: String
        let status: String
        let timestamp: Date?
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
