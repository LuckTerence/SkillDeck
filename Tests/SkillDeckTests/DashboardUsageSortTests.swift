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

    // MARK: - In-place Refresh

    /// A forced refresh must not freeze the list into name order or hide badges. Ordering changes
    /// exactly once, when the new counts arrive.
    @MainActor
    func testRefreshingDoesNotFreezeUsageOrder() async {
        let codex = GatedDashboardUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])
        manager.skills = [
            // Names are deliberately opposite to the usage order so a name-sort freeze is visible.
            makeSkill(id: "a", name: "Zulu"),
            makeSkill(id: "b", name: "Alpha"),
        ]

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(summaryResult(["a": 5, "b": 1]))
        await initial.value

        let viewModel = makeViewModel(manager: manager)
        assertOrder(viewModel, ["a", "b"])

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }

        XCTAssertFalse(viewModel.isRelevantUsagePending)
        XCTAssertTrue(viewModel.isRelevantUsageRefreshing)
        XCTAssertEqual(viewModel.usageSummary(for: manager.skills[0])?.count, 5)
        assertOrder(viewModel, ["a", "b"])

        await codex.release(summaryResult(["a": 1, "b": 9]))
        await refresh.value

        XCTAssertFalse(viewModel.isRelevantUsageRefreshing)
        assertOrder(viewModel, ["b", "a"])
    }

    /// Two Dashboard windows sharing one manager must not both refresh the same Agent, even when
    /// the first scan finishes before the second window's call runs.
    @MainActor
    func testAutoRefreshRelevantUsageIsAtomicAcrossCallers() async {
        let codex = StubUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        await manager.loadSkillUsage()

        let viewModelA = makeViewModel(manager: manager)
        let viewModelB = makeViewModel(manager: manager)
        let expiredNow = Date().addingTimeInterval(
            DashboardViewModel.usageAutoRefreshInterval + 60
        )

        async let first: Void = viewModelA.autoRefreshRelevantUsage(now: expiredNow)
        async let second: Void = viewModelB.autoRefreshRelevantUsage(now: expiredNow)
        _ = await (first, second)

        let scanCount = await codex.scanCount
        XCTAssertEqual(scanCount, 2) // initial scan + exactly one auto refresh
    }

    /// The Dashboard list stays mounted next to an open detail pane. Automatic refresh must be
    /// suppressed there so window activation does not reshuffle the list behind the inspector.
    @MainActor
    func testAutoRefreshSkipsWhileDetailIsOpen() async {
        let codex = StubUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        await manager.loadSkillUsage()

        let viewModel = makeViewModel(manager: manager)
        let expiredNow = Date().addingTimeInterval(
            DashboardViewModel.usageAutoRefreshInterval + 60
        )

        await viewModel.autoRefreshRelevantUsage(now: expiredNow, isDetailOpen: true)
        let scanCountWithDetail = await codex.scanCount
        XCTAssertEqual(scanCountWithDetail, 1)

        // Closing the detail pane makes the Dashboard eligible again.
        await viewModel.autoRefreshRelevantUsage(now: expiredNow, isDetailOpen: false)
        let scanCountAfterClose = await codex.scanCount
        XCTAssertEqual(scanCountAfterClose, 2)
    }

    /// An Agent without a usage provider produces an empty scope; the toolbar must not offer a
    /// refresh control that would immediately return without doing anything.
    @MainActor
    func testRefreshControlIsHiddenWithoutRelevantAgent() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha", agents: [.claudeCode])]
        let viewModel = makeViewModel(manager: manager)

        viewModel.selectedAgentFilter = .claudeCode
        XCTAssertFalse(viewModel.canRefreshRelevantUsage)

        viewModel.selectedAgentFilter = nil
        XCTAssertTrue(viewModel.canRefreshRelevantUsage)
    }

    /// Window activation only refreshes when the Dashboard is in usage order.
    @MainActor
    func testAutoRefreshRelevantUsageRequiresUsageSort() async {
        let codex = StubUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        await manager.loadSkillUsage()

        let viewModel = DashboardViewModel(skillManager: manager)
        viewModel.sortOrder = .name
        let expiredNow = Date().addingTimeInterval(
            DashboardViewModel.usageAutoRefreshInterval + 60
        )

        await viewModel.autoRefreshRelevantUsage(now: expiredNow)
        let scanCountInNameOrder = await codex.scanCount
        XCTAssertEqual(scanCountInNameOrder, 1)

        viewModel.sortOrder = .usage
        await viewModel.autoRefreshRelevantUsage(now: expiredNow)
        let scanCountInUsageOrder = await codex.scanCount
        XCTAssertEqual(scanCountInUsageOrder, 2)
    }

    /// Automatic refresh never starts a first scan and never duplicates an in-flight one.
    @MainActor
    func testAutoRefreshSkipsPendingOrInFlight() async {
        let expiredNow = Date().addingTimeInterval(
            DashboardViewModel.usageAutoRefreshInterval + 60
        )

        // Never scanned: the lazy Dashboard path owns the first scan.
        let unscannedProvider = StubUsageProvider(agentType: .codex)
        let unscannedManager = SkillManager(skillUsageProviders: [unscannedProvider])
        unscannedManager.skills = [makeSkill(id: "a", name: "Alpha")]
        let unscannedViewModel = makeViewModel(manager: unscannedManager)
        await unscannedViewModel.autoRefreshRelevantUsage(now: expiredNow)
        let unscannedScanCount = await unscannedProvider.scanCount
        XCTAssertEqual(unscannedScanCount, 0)

        // First scan in flight.
        let scanningManager = SkillManager(
            skillUsageProviders: [StubUsageProvider(agentType: .codex)]
        )
        scanningManager.skills = [makeSkill(id: "a", name: "Alpha")]
        scanningManager.skillUsageScanStates = [.codex: .scanning]
        let scanningViewModel = makeViewModel(manager: scanningManager)
        await scanningViewModel.autoRefreshRelevantUsage(now: expiredNow)
        XCTAssertEqual(scanningManager.skillUsageScanState(for: .codex), .scanning)

        // Forced refresh already in flight.
        let gated = GatedDashboardUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [gated])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        manager.skillUsageScanStates = [.codex: availableState]
        let viewModel = makeViewModel(manager: manager)

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await gated.scanCount == 1 }

        await viewModel.autoRefreshRelevantUsage(now: expiredNow)
        let gatedScanCount = await gated.scanCount
        XCTAssertEqual(gatedScanCount, 1)

        await gated.release(summaryResult([:]))
        await refresh.value
    }

    // MARK: - Stale State

    @MainActor
    func testStaleStateIsIncludedInSummaryAndPartial() {
        let manager = makeManager(agents: [.codex])
        manager.skills = [makeSkill(id: "a", name: "Alpha")]
        manager.skillUsageRecords = [.codex: ["a": record(5)]]
        manager.skillUsageScanStates = [.codex: .stale(failedLogCount: 2)]

        let viewModel = makeViewModel(manager: manager)

        let summary = viewModel.usageSummary(for: manager.skills[0])
        XCTAssertEqual(summary?.count, 5)
        XCTAssertTrue(summary?.isPartial ?? false)
        XCTAssertEqual(viewModel.relevantUsageFailedLogCount, 2)
    }

    @MainActor
    func testStaleStateParticipatesInUsageSorting() {
        let manager = makeManager(agents: [.claudeCode, .codex])
        manager.skills = [
            makeSkill(id: "a", name: "Alpha"),
            makeSkill(id: "b", name: "Beta"),
            makeSkill(id: "c", name: "Charlie"),
        ]
        manager.skillUsageRecords = [
            .codex: ["a": record(1)],
            .claudeCode: ["b": record(5)],
        ]
        manager.skillUsageScanStates = [
            .codex: .stale(failedLogCount: 1),
            .claudeCode: availableState,
        ]

        let viewModel = makeViewModel(manager: manager)

        // Both counts participate; the unknown skill still sorts last.
        assertOrder(viewModel, ["b", "a", "c"])
    }

    // MARK: - Fixtures

    private var availableState: SkillUsageScanState {
        .available(scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0)
    }

    private func record(_ count: Int) -> SkillUsageRecord {
        SkillUsageRecord(detectedInvocationCount: count, lastDetectedAt: nil)
    }

    private func summaryResult(_ counts: [String: Int]) -> SkillUsageScanResult {
        SkillUsageScanResult(
            records: counts.mapValues { record($0) },
            scannedLogCount: counts.isEmpty ? 0 : 1,
            preservedLogCount: 0,
            failedLogCount: 0
        )
    }

    /// Polls the provider's actor-isolated counter while a scan is suspended on its continuation.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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

private actor StubUsageProvider: SkillUsageProvider {
    nonisolated let agentType: AgentType
    private(set) var scanCount = 0

    init(agentType: AgentType) {
        self.agentType = agentType
    }

    func scan() async -> SkillUsageScanResult {
        scanCount += 1
        return SkillUsageScanResult(
            records: [:],
            scannedLogCount: 0,
            preservedLogCount: 0,
            failedLogCount: 0
        )
    }
}

/// Like production providers, this one ignores cancellation and only finishes when released.
private actor GatedDashboardUsageProvider: SkillUsageProvider {
    nonisolated let agentType: AgentType
    private var continuation: CheckedContinuation<SkillUsageScanResult, Never>?
    private(set) var scanCount = 0

    init(agentType: AgentType) {
        self.agentType = agentType
    }

    func scan() async -> SkillUsageScanResult {
        scanCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ result: SkillUsageScanResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
