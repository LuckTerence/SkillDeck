import Foundation

/// Recovers skill activations from Claude Code's project JSONL transcripts.
///
/// Claude Code writes no dedicated activation record. Both invocation paths expand the skill
/// prompt and prepend `Base directory for this skill: <path>`:
/// - a user slash command such as `/gzh-design`
/// - the model's `Skill` tool call
///
/// Counting that marker counts each activation exactly once and naturally excludes built-in
/// slash commands, failed `Skill` calls, and plain tool output that happens to contain the text.
actor ClaudeCodeSkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .claudeCode }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [claudeDirectory.appendingPathComponent("projects", isDirectory: true)],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-claude-code.json"),
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

    private static let skillMarker = "Base directory for this skill: "

    private static let parse: @Sendable (String) -> [SkillUsageEvent] = { line in
        guard line.contains(skillMarker) else { return [] }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = userMessageText(from: object),
              let skillID = skillID(from: text) else {
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

    /// Returns text only for real user prompts, never for `tool_result` blocks.
    ///
    /// A tool result can contain the marker when a user greps SKILL.md files; counting that
    /// would invent usage. Skill expansion content is stored as plain text or text blocks.
    private static func userMessageText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              let message = object["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }

        if let text = content as? String {
            return text
        }

        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func skillID(from text: String) -> String? {
        guard let markerRange = text.range(of: skillMarker) else { return nil }

        // Claude Code separates the skill root from the SKILL.md body with two spaces.
        // Limiting to the first line also matches Qoder-style expansions.
        let pathLine = String(text[markerRange.upperBound...].prefix { !$0.isNewline })
        let path = (pathLine.components(separatedBy: "  ").first ?? pathLine)
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        let skillID = URL(fileURLWithPath: path).lastPathComponent
        return skillID.isEmpty ? nil : skillID
    }
}
