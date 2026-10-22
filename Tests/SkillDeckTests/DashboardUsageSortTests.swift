import XCTest

@testable import SkillDeck

final class DashboardUsageSortTests: XCTestCase {

    // MARK: - Aggregation

    @MainActor
    func testUsageSortSumsAcrossAvailableAgents() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
            makeSkill(id: "c", name: "Gamma"),
        ]
        manager.skillUsageRecords = [
            .codex: ["a": record(5), "b": record(2)],
            .claudeCode: ["a": record(2)],
        ]
        manager.skillUsageScanStates = [
            .codex: availableState,
            .claudeCode: availableState,
        ]

        let viewModel = makeViewModel(manager: manager)

        assertOrder(viewModel, ["a", "b", "c"])
        XCTAssertEqual(viewModel.usageSummary(for: manager.skills[0])?.count, 7)
    }

    @MainActor
    func testUsageSortUsesFilteredAgentCount() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha", agents: [.claudeCode]),
            makeSkill(id: "b", name: "Beta", agents: [.claudeCode]),
        ]
        manager.skillUsageRecords = [
            .codex: ["a": record(9)],
            .claudeCode: ["b": record(5)],
        ]
        manager.skillUsageScanStates = [
            .codex: availableState,
            .claudeCode: availableState,
        ]

        let viewModel = makeViewModel(manager: manager)
        XCTAssertEqual(viewModel.filteredSkills.map(\.id), ["a", "b"])

        viewModel.selectedAgentFilter = .claudeCode

        assertOrder(viewModel, ["b", "a"])
        let summary = viewModel.usageSummary(for: manager.skills[1])
        XCTAssertEqual(summary?.count, 5)
        XCTAssertEqual(summary?.agentCounts.keys.map { $0 }, [.claudeCode])
    }

    @MainActor
    func testUsageCountIncludesUninstalledAgentHistory() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
        ]
        manager.skillUsageRecords = [
            .codex: ["a": record(1)],
        ]
        manager.skillUsageScanStates = [.codex: availableState]

        let viewModel = makeViewModel(manager: manager)

        assertOrder(viewModel, ["a", "b"])
        XCTAssertEqual(viewModel.usageSummary(for: manager.skills[0])?.count, 1)
    }

    @MainActor
    func testAvailableAgentWithoutRecordIsZero() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        manager.skillUsageScanStates = [.codex: availableState]

        let viewModel = makeViewModel(manager: manager)

        let summary = viewModel.usageSummary(for: manager.skills[0])
        XCTAssertEqual(summary?.count, 0)
        XCTAssertFalse(summary?.isPartial ?? true)
    }

    // MARK: - Unknown Usage

    @MainActor
    func testUnknownUsageSortsByNameInBothDirections() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "c", name: "Charlie"),
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
        ]
        manager.skillUsageScanStates = [
            .claudeCode: .unavailable,
            .codex: .unavailable,
        ]

        let viewModel = makeViewModel(manager: manager)

        XCTAssertNil(viewModel.usageSummary(for: manager.skills[0]))
        assertOrder(viewModel, ["a", "b", "c"])

        viewModel.sortDirection = .ascending
        assertOrder(viewModel, ["a", "b", "c"])
    }

    @MainActor
    func testUsageSortFreezesWhenRelevantProviderIsScanning() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
        ]
        manager.skillUsageRecords = [.codex: ["b": record(9)]]
        manager.skillUsageScanStates = [
            .codex: availableState,
            .claudeCode: .scanning,
        ]

        let viewModel = makeViewModel(manager: manager)

        XCTAssertTrue(viewModel.isRelevantUsagePending)
        assertOrder(viewModel, ["a", "b"])
    }

    @MainActor
    func testIrrelevantProviderScanningDoesNotFreezeFilteredView() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha", agents: [.claudeCode]),
            makeSkill(id: "b", name: "Beta", agents: [.claudeCode]),
        ]
        manager.skillUsageRecords = [.claudeCode: ["a": record(1), "b": record(9)]]
        manager.skillUsageScanStates = [
            .claudeCode: availableState,
            .codex: .scanning,
        ]

        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAgentFilter = .claudeCode

        XCTAssertFalse(viewModel.isRelevantUsagePending)
        assertOrder(viewModel, ["b", "a"])
    }

    // MARK: - Ordering Rules

    @MainActor
    func testUsageSortTieBreaksByNameAscending() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [
            makeSkill(id: "z", name: "Zulu"),
            makeSkill(id: "a", name: "alpha"),
        ]
        manager.skillUsageRecords = [.codex: ["z": record(3), "a": record(3)]]
        manager.skillUsageScanStates = [.codex: availableState]

        let viewModel = makeViewModel(manager: manager, direction: .descending)

        assertOrder(viewModel, ["a", "z"])
    }

    @MainActor
    func testUsageSortTieBreaksByIDWhenDisplayNamesMatch() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [
            makeSkill(id: "b-skill", name: "Same"),
            makeSkill(id: "a-skill", name: "same"),
        ]
        manager.skillUsageRecords = [
            .codex: ["b-skill": record(3), "a-skill": record(3)],
        ]
        manager.skillUsageScanStates = [.codex: availableState]

        let viewModel = makeViewModel(manager: manager, direction: .descending)
        assertOrder(viewModel, ["a-skill", "b-skill"])

        viewModel.sortDirection = .ascending
        assertOrder(viewModel, ["a-skill", "b-skill"])
    }

    @MainActor
    func testUsageSortAscendingDirection() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
            makeSkill(id: "c", name: "Charlie"),
        ]
        manager.skillUsageRecords = [
            .codex: ["a": record(5), "b": record(1)],
        ]
        manager.skillUsageScanStates = [.codex: availableState]

        let viewModel = makeViewModel(manager: manager, direction: .ascending)

        assertOrder(viewModel, ["c", "b", "a"])
    }

    @MainActor
    func testUsageDefaultDirectionIsDescending() {
        XCTAssertEqual(DashboardViewModel.SortOrder.usage.defaultDirection, .descending)
        XCTAssertEqual(DashboardViewModel.SortOrder.name.defaultDirection, .ascending)
    }

    // MARK: - Partial Results

    @MainActor
    func testPartialSummaryWhenProviderFails() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        manager.skillUsageRecords = [.codex: ["a": record(3)]]
        manager.skillUsageScanStates = [
            .codex: availableState,
            .claudeCode: .failed(failedLogCount: 2),
        ]

        let viewModel = makeViewModel(manager: manager)

        let summary = viewModel.usageSummary(for: manager.skills[0])
        XCTAssertEqual(summary?.count, 3)
        XCTAssertEqual(summary?.agentCounts.keys.map { $0 }, [.codex])
        XCTAssertTrue(summary?.isPartial ?? false)
    }

    @MainActor
    func testPartialFlagIgnoresFailuresOutsideFilter() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha", agents: [.claudeCode])]
        manager.skillUsageRecords = [.claudeCode: ["a": record(4)]]
        manager.skillUsageScanStates = [
            .claudeCode: availableState,
            .codex: .failed(failedLogCount: 5),
        ]

        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAgentFilter = .claudeCode

        let summary = viewModel.usageSummary(for: manager.skills[0])
        XCTAssertEqual(summary?.count, 4)
        XCTAssertEqual(summary?.agentCounts.keys.map { $0 }, [.claudeCode])
        XCTAssertFalse(summary?.isPartial ?? true)
    }

    @MainActor
    func testPartialFlagIncludesRelevantFailures() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha", agents: [.codex])]
        manager.skillUsageScanStates = [
            .claudeCode: availableState,
            .codex: .failed(failedLogCount: 1),
        ]

        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAgentFilter = .codex

        XCTAssertNil(viewModel.usageSummary(for: manager.skills[0]))
        XCTAssertEqual(viewModel.relevantUsageFailedLogCount, 1)
    }

    // MARK: - Scoping

    @MainActor
    func testRelevantUnscannedUsageRespectsFilter() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha", agents: [.claudeCode])]
        manager.skillUsageScanStates = [
            .claudeCode: availableState,
            .codex: .notScanned,
        ]

        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAgentFilter = .claudeCode
        XCTAssertFalse(viewModel.hasUnscannedRelevantUsage)

        viewModel.selectedAgentFilter = nil
        XCTAssertTrue(viewModel.hasUnscannedRelevantUsage)
    }

    @MainActor
    func testFilteredUnsupportedProviderStaysIdle() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [
            makeSkill(id: "b", name: "Beta", agents: [.claudeCode]),
            makeSkill(id: "a", name: "Alpha", agents: [.claudeCode]),
        ]

        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAgentFilter = .claudeCode

        XCTAssertTrue(viewModel.relevantUsageAgents.isEmpty)
        XCTAssertFalse(viewModel.isRelevantUsagePending)
        XCTAssertNil(viewModel.usageSummary(for: manager.skills[0]))
        assertOrder(viewModel, ["a", "b"])
    }

    // MARK: - Fixtures

    private var availableState: SkillUsageScanState {
        .available(scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0)
    }

    private func record(_ count: Int) -> SkillUsageRecord {
        SkillUsageRecord(detectedInvocationCount: count, lastDetectedAt: nil)
    }

    @MainActor
    private func makeManager(agents: [AgentType]) -> SkillManager {
        SkillManager(skillUsageProviders: agents.map {
            StubUsageProvider(agentType: $0)
        })
    }

    @MainActor
    private func makeViewModel(
        manager: SkillManager,
        direction: DashboardViewModel.SortDirection = .descending
    ) -> DashboardViewModel {
        let viewModel = DashboardViewModel(skillManager: manager)
        viewModel.sortOrder = .usage
        viewModel.sortDirection = direction
        return viewModel
    }

    @MainActor
    private func assertOrder(
        _ viewModel: DashboardViewModel,
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(viewModel.filteredSkills.map(\.id), expected, file: file, line: line)
    }

    private func makeSkill(
        id: String,
        name: String? = nil,
        agents: [AgentType] = []
    ) -> Skill {
        Skill(
            id: id,
            canonicalURL: URL(fileURLWithPath: "/tmp/skills/\(id)"),
            metadata: SkillMetadata(name: name ?? id, description: ""),
            markdownBody: "",
            scope: .sharedGlobal,
            installations: agents.map {
                SkillInstallation(
                    agentType: $0,
                    path: URL(fileURLWithPath: "/tmp/\($0.rawValue)/\(id)"),
                    isSymlink: false
                )
            },
            lockEntry: nil
        )
    }
}

private struct StubUsageProvider: SkillUsageProvider {
    let agentType: AgentType

    func scan() async -> SkillUsageScanResult {
        SkillUsageScanResult(
            records: [:],
            scannedLogCount: 0,
            preservedLogCount: 0,
            failedLogCount: 0
        )
    }
}
