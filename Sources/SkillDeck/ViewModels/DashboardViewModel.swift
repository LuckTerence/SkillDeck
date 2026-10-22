import Foundation

/// DashboardViewModel manages the state and interaction logic for the Dashboard page
///
/// In the MVVM architecture, the ViewModel acts as a bridge between View and Model:
/// - View observes ViewModel state changes through data binding
/// - View user actions invoke ViewModel methods
/// - ViewModel calls Service layer to handle business logic
///
/// @Observable enables SwiftUI to automatically track property changes and refresh the UI
/// @MainActor ensures all state modifications happen on the main thread (UI-safe)
@MainActor
@Observable
final class DashboardViewModel {

    /// Search keyword
    var searchText = ""

    /// Currently selected Agent filter (nil means show all)
    var selectedAgentFilter: AgentType?

    /// Sort order
    var sortOrder: SortOrder = .name

    /// Sort direction (ascending/descending)
    var sortDirection: SortDirection = .ascending

    /// Currently selected skill (used for navigation to detail page)
    var selectedSkillID: String?

    /// Whether to show delete confirmation dialog
    var showDeleteConfirmation = false

    /// Skill pending deletion
    var skillToDelete: Skill?

    /// Sort direction enum
    /// Swift enums can conform to multiple protocols:
    /// - CaseIterable: provides allCases collection for iterating over enum values
    enum SortDirection: CaseIterable {
        case ascending
        case descending

        /// Toggle sort direction, returning the opposite direction
        var toggled: SortDirection {
            self == .ascending ? .descending : .ascending
        }

        /// SF Symbols icon name: ascending uses up arrow, descending uses down arrow
        var iconName: String {
            self == .ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
        }

        /// Display text
        var displayName: String {
            self == .ascending ? "Ascending" : "Descending"
        }
    }

    /// Sort order enum
    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case scope = "Scope"
        case agent = "Agent Count"
        case usage = "Usage Count"

        /// Each sort order corresponds to an SF Symbol icon
        var iconName: String {
            switch self {
            case .name: return "textformat.abc"
            case .scope: return "scope"
            case .agent: return "cpu"
            case .usage: return "chart.bar.xaxis"
            }
        }

        /// Direction applied when the user switches to this field.
        var defaultDirection: SortDirection {
            switch self {
            case .usage: return .descending
            default: return .ascending
            }
        }
    }

    /// Reference to global SkillManager (dependency injection)
    let skillManager: SkillManager

    init(skillManager: SkillManager) {
        self.skillManager = skillManager
    }

    // MARK: - Usage Scope

    /// Agents whose usage contributes to the current sort/badge.
    /// Unsupported Agents are excluded: `skillUsageScanState` reports their missing
    /// entry as `.notScanned`, which would otherwise make the list spin/freeze forever.
    var relevantUsageAgents: [AgentType] {
        let candidates = selectedAgentFilter.map { [$0] }
            ?? skillManager.skillUsageSupportedAgents
        return candidates.filter { skillManager.isSkillUsageSupported($0) }
    }

    var hasUnscannedRelevantUsage: Bool {
        relevantUsageAgents.contains {
            skillManager.skillUsageScanState(for: $0) == .notScanned
        }
    }

    var isRelevantUsageScanning: Bool {
        relevantUsageAgents.contains {
            skillManager.skillUsageScanState(for: $0) == .scanning
        }
    }

    /// True before or while the relevant scans finish; freezes ordering and shows a spinner.
    var isRelevantUsagePending: Bool {
        hasUnscannedRelevantUsage || isRelevantUsageScanning
    }

    /// Failed log count restricted to the current scope, used by `isPartial`.
    var relevantUsageFailedLogCount: Int {
        relevantUsageAgents.reduce(0) { total, agent in
            switch skillManager.skillUsageScanState(for: agent) {
            case .available(_, _, let failed), .failed(let failed):
                return total + failed
            default:
                return total
            }
        }
    }

    /// Localization key for the unknown placeholder, also scoped to relevant Agents.
    var unknownUsageHelpKey: String {
        if isRelevantUsagePending { return L10nKeys.usageAgentScanning }
        if relevantUsageFailedLogCount > 0 { return L10nKeys.usageAgentUnreadable }
        return L10nKeys.usageAgentUnavailable
    }

    /// Aggregated usage for one skill, respecting the current Agent filter.
    /// Returns nil when no relevant Agent has readable usage history.
    func usageSummary(for skill: Skill) -> SkillUsageSummary? {
        var agentCounts: [AgentType: Int] = [:]

        for agent in relevantUsageAgents {
            guard case .available = skillManager.skillUsageScanState(for: agent) else {
                continue
            }
            agentCounts[agent] = skillManager.skillUsage(for: skill.id, agent: agent)?
                .detectedInvocationCount ?? 0
        }

        guard !agentCounts.isEmpty else { return nil }

        return SkillUsageSummary(
            count: agentCounts.values.reduce(0, +),
            agentCounts: agentCounts,
            isPartial: isRelevantUsagePending || relevantUsageFailedLogCount > 0
        )
    }

    private func isOrderedBeforeByName(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let lhsName = lhs.displayName.lowercased()
        let rhsName = rhs.displayName.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.id < rhs.id
    }

    /// Calculates the list of skills to display based on current search, filter, and sort conditions
    /// Computed property: dynamically calculated on each access, similar to Java getter
    var filteredSkills: [Skill] {
        var result = skillManager.skills

        // 1. Search filtering
        if !searchText.isEmpty {
            result = skillManager.search(query: searchText)
        }

        // 2. Agent filtering
        if let agent = selectedAgentFilter {
            result = result.filter { skill in
                skill.installations.contains { $0.agentType == agent }
            }
        }

        // 3. Sorting (ascending or descending based on sort direction)
        // In Swift closures, $0 and $1 are anonymous parameters, similar to Kotlin's it
        let ascending = sortDirection == .ascending
        switch sortOrder {
        case .name:
            result.sort {
                ascending
                    ? $0.displayName.lowercased() < $1.displayName.lowercased()
                    : $0.displayName.lowercased() > $1.displayName.lowercased()
            }
        case .scope:
            result.sort {
                ascending
                    ? $0.scope.displayName < $1.scope.displayName
                    : $0.scope.displayName > $1.scope.displayName
            }
        case .agent:
            // Agent Count defaults to descending (most first) for better visibility
            result.sort {
                ascending
                    ? $0.installations.count < $1.installations.count
                    : $0.installations.count > $1.installations.count
            }
        case .usage:
            // Freeze only while a relevant Agent is pending. Providers outside the current
            // filter may still be scanning in the background without reshuffling this view.
            guard !isRelevantUsagePending else {
                result.sort(by: isOrderedBeforeByName)
                break
            }

            // Precompute once: the comparator runs O(n log n) times.
            let counts = Dictionary(
                uniqueKeysWithValues: result.map { ($0.id, usageSummary(for: $0)?.count) }
            )

            result.sort { lhs, rhs in
                switch (counts[lhs.id] ?? nil, counts[rhs.id] ?? nil) {
                case let (lhsCount?, rhsCount?):
                    if lhsCount != rhsCount {
                        return ascending ? lhsCount < rhsCount : lhsCount > rhsCount
                    }
                case (nil, .some):
                    // Unknown usage always sorts after known values, in both directions.
                    return false
                case (.some, nil):
                    return true
                case (nil, nil):
                    break
                }
                return isOrderedBeforeByName(lhs, rhs)
            }
        }

        return result
    }

    /// Requests skill deletion (shows confirmation dialog first)
    func requestDelete(skill: Skill) {
        skillToDelete = skill
        showDeleteConfirmation = true
    }

    /// Confirms deletion
    func confirmDelete() async {
        guard let skill = skillToDelete else { return }
        do {
            try await skillManager.deleteSkill(skill)
        } catch {
            skillManager.errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        skillToDelete = nil
        showDeleteConfirmation = false
    }

    /// Cancels deletion
    func cancelDelete() {
        skillToDelete = nil
        showDeleteConfirmation = false
    }
}
