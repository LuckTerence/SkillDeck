import Foundation

/// Recovers skill activations from Qoder's Claude-Code-compatible project JSONL history.
///
/// A single `/skill` invocation produces several records in the same session:
/// a user command message, a system activation message, and a user message containing the
/// expanded SKILL.md. Only the system message is counted, which is exactly one record per
/// successful activation.
actor QoderSkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .qoder }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let qoderDirectory = homeDirectory.appendingPathComponent(".qoder", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [qoderDirectory.appendingPathComponent("projects", isDirectory: true)],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-qoder.json"),
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
        guard line.contains("Skill **") else { return [] }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "system",
              let content = object["content"] as? String,
              let skillID = activatedSkillID(from: content) else {
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

    /// Matches the exact Qoder system message: `Skill **<id>** activated.`
    private static func activatedSkillID(from content: String) -> String? {
        let prefix = "Skill **"
        let suffix = "** activated."
        guard content.hasPrefix(prefix), content.hasSuffix(suffix) else { return nil }

        let skillID = content.dropFirst(prefix.count).dropLast(suffix.count)
        return skillID.isEmpty ? nil : String(skillID)
    }
}
