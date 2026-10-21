import Foundation

/// Recovers skill invocations from CodeBuddy's project JSONL history.
///
/// Counting results instead of calls gives exact success semantics: a failed call still has a
/// `function_call` event, but only successful calls produce a completed `function_call_result`
/// whose output starts with `Base directory for this skill: <path>`.
actor CodeBuddySkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .codeBuddy }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let codeBuddyDirectory = homeDirectory
            .appendingPathComponent(".codebuddy", isDirectory: true)
        let agentsDirectory = homeDirectory
            .appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [codeBuddyDirectory.appendingPathComponent("projects", isDirectory: true)],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-codebuddy.json"),
            fileManager: fileManager,
            parse: Self.parse,
            parserVersion: 2
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
            parse: Self.parse,
            parserVersion: 2
        )
    }

    func scan() -> SkillUsageScanResult {
        scanner.scan()
    }

    private static let parse: @Sendable (String) -> [SkillUsageEvent] = { line in
        guard line.contains("function_call_result"),
              line.contains(CodeBuddySkillUsageService.skillMarker) else {
            return []
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "function_call_result",
              let toolName = object["name"] as? String,
              toolName == "Skill" || toolName == "REPL",
              object["status"] as? String == "completed",
              let output = object["output"] as? [String: Any],
              let text = output["text"] as? String,
              let skillID = skillID(from: text) else {
            return []
        }

        return [
            SkillUsageEvent(
                skillID: skillID,
                timestamp: SkillUsageTimestampParser.parseMilliseconds(object["timestamp"])
            )
        ]
    }

    private static let skillMarker = "Base directory for this skill: "

    private static func skillID(from output: String) -> String? {
        let text = unwrappedResult(from: output)
        guard let markerRange = text.range(of: skillMarker) else { return nil }

        let path = text[markerRange.upperBound...]
            .prefix { !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        let skillID = URL(fileURLWithPath: path).lastPathComponent
        return skillID.isEmpty ? nil : skillID
    }

    /// Newer CodeBuddy releases invoke skills through the REPL sandbox and wrap the skill output
    /// as a JSON-encoded `result` string inside `output.text`.
    private static func unwrappedResult(from output: String) -> String {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? String else {
            return output
        }
        return result
    }
}
