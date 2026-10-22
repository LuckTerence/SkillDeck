import Foundation

/// Recovers skill invocations from GitHub Copilot CLI's session event history.
///
/// Copilot CLI appends JSONL events to
/// `~/.copilot/session-state/<session-id>/events.jsonl`. Unlike transcript-based agents,
/// it emits a dedicated `skill.invoked` event for each skill invocation, so no
/// prompt-marker or tool-output heuristics are needed. Whether failed calls also emit this
/// event is only recorded as an observation; the metric remains a detected invocation count.
/// The event's `data` object contains the skill `name` and the `path` to its `SKILL.md`.
actor CopilotSkillUsageService: SkillUsageProvider {
    /// Agent whose local history this adapter reads.
    nonisolated var agentType: AgentType { .copilotCLI }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let copilotDirectory = homeDirectory.appendingPathComponent(".copilot", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [
                copilotDirectory.appendingPathComponent("session-state", isDirectory: true),
            ],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-copilot-cli.json"),
            fileManager: fileManager,
            parse: Self.parse
        )
    }

    /// Test initializer that avoids depending on the developer machine's real history.
    init(
        historyDirectories: [URL],
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.scanner = SkillUsageJSONLScanner(
            directories: historyDirectories,
            cacheURL: cacheURL,
            fileManager: fileManager,
            parse: Self.parse
        )
    }

    func scan() -> SkillUsageScanResult {
        scanner.scan()
    }

    private static let parse: @Sendable (String) -> [SkillUsageEvent] = { line in
        // Most events are tool calls and messages. Skip JSON decoding for them.
        guard line.contains("skill.invoked") else { return [] }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "skill.invoked",
              let payload = object["data"] as? [String: Any],
              let skillID = skillID(from: payload) else {
            return []
        }

        return [
            SkillUsageEvent(
                skillID: skillID,
                timestamp: (object["timestamp"] as? String)
                    .flatMap(SkillUsageTimestampParser.parseISO8601)
            )
        ]
    }

    /// SkillDeck keys usage by skill directory name (`Skill.id`), so prefer the directory that
    /// contains `SKILL.md`. Copilot's `name` is the frontmatter value and is used as a fallback
    /// when the path is missing or does not point to a `SKILL.md`.
    private static func skillID(from payload: [String: Any]) -> String? {
        if let path = payload["path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == "SKILL.md" {
                let directoryName = url.deletingLastPathComponent().lastPathComponent
                if !directoryName.isEmpty {
                    return directoryName
                }
            }
        }

        if let name = payload["name"] as? String, !name.isEmpty {
            return name
        }

        return nil
    }
}
