import Foundation

/// A single skill's usage evidence recovered from local Agent history.
///
/// The count intentionally represents detected invocation evidence, not a guarantee that every
/// historical invocation was captured. Agent history can be disabled, deleted, or written in a
/// format that an older SkillDeck release does not understand.
struct SkillUsageRecord: Codable, Equatable, Sendable {
    /// Number of distinct Agent tool-call events that referenced this skill.
    let detectedInvocationCount: Int

    /// Timestamp of the newest matching tool-call event, when the log provided a valid timestamp.
    let lastDetectedAt: Date?
}

/// Observable lifecycle state for a local usage-history scan.
///
/// Associated values let the `.available` case carry scan coverage without introducing a second
/// state variable that could become inconsistent with the enum.
enum SkillUsageScanState: Equatable, Sendable {
    /// No scan has started during this app launch.
    case notScanned
    case scanning
    /// At least one history file contributes records (read now, cache hit, or preserved from
    /// the previous scan). `failedLogCount` may still be non-zero.
    case available(scannedLogCount: Int, preservedLogCount: Int, failedLogCount: Int)
    /// A history source exists, but none of it could be read and no cache is available.
    case failed(failedLogCount: Int)
    /// No history source exists on this machine.
    case unavailable
}

/// Complete result returned by an Agent-specific usage-history adapter.
struct SkillUsageScanResult: Equatable, Sendable {
    /// Records are keyed by the skill directory name, which is also `Skill.id` in SkillDeck.
    let records: [String: SkillUsageRecord]
    /// Files contributing records: read now, fingerprint cache hit, or preserved from cache.
    let scannedLogCount: Int
    /// Subset of `scannedLogCount` restored only because this scan could not read the file.
    /// These counts may be stale and must not be presented as freshly observed.
    let preservedLogCount: Int
    let failedLogCount: Int
}

/// One detected invocation recovered from a single history record.
struct SkillUsageEvent: Equatable, Sendable {
    let skillID: String
    let timestamp: Date?
}
