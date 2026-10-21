import XCTest

@testable import SkillDeck

final class SkillManagerUsageTests: XCTestCase {
    @MainActor
    func testLoadSkillUsageAggregatesProvidersAndCachesResults() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: SkillUsageScanResult(
                records: [
                    "find-skills": SkillUsageRecord(
                        detectedInvocationCount: 2,
                        lastDetectedAt: nil
                    ),
                ],
                scannedLogCount: 3,
                preservedLogCount: 0,
                failedLogCount: 1
            )
        )
        let openCode = FakeSkillUsageProvider(
            agentType: .openCode,
            result: SkillUsageScanResult(
                records: [
                    "web-access": SkillUsageRecord(
                        detectedInvocationCount: 1,
                        lastDetectedAt: nil
                    ),
                ],
                scannedLogCount: 1,
                preservedLogCount: 0,
                failedLogCount: 0
            )
        )
        let manager = SkillManager(skillUsageProviders: [codex, openCode])

        await manager.loadSkillUsage()

        XCTAssertEqual(
            manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount,
            2
        )
        XCTAssertEqual(
            manager.skillUsage(for: "web-access", agent: .openCode)?.detectedInvocationCount,
            1
        )
        XCTAssertEqual(
            manager.skillUsageScanState(for: .codex),
            .available(scannedLogCount: 3, preservedLogCount: 0, failedLogCount: 1)
        )
        XCTAssertEqual(manager.skillUsageFailedLogCount, 1)
        XCTAssertTrue(manager.isSkillUsageSupported(.codex))
        XCTAssertFalse(manager.isSkillUsageSupported(.claudeCode))

        let firstCodexScanCount = await codex.scanCount
        await manager.loadSkillUsage()
        let secondCodexScanCount = await codex.scanCount
        XCTAssertEqual(secondCodexScanCount, firstCodexScanCount)

        await manager.loadSkillUsage(forceRefresh: true)
        let forcedCodexScanCount = await codex.scanCount
        XCTAssertEqual(forcedCodexScanCount, firstCodexScanCount + 1)
    }

    @MainActor
    func testUnavailableProviderIsNotRescannedUntilForced() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 0
            )
        )
        let manager = SkillManager(skillUsageProviders: [codex])

        await manager.loadSkillUsage()

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .unavailable)
        XCTAssertFalse(manager.hasUnscannedSkillUsage)

        let firstScanCount = await codex.scanCount
        await manager.loadSkillUsage()
        let secondScanCount = await codex.scanCount
        XCTAssertEqual(secondScanCount, firstScanCount)
    }

    /// A source that exists but cannot be read must stay visible as a failure, not as "no usage".
    @MainActor
    func testAllUnreadableHistoryIsReportedAsFailed() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 1
            )
        )
        let manager = SkillManager(skillUsageProviders: [codex])

        await manager.loadSkillUsage()

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .failed(failedLogCount: 1))
        XCTAssertEqual(manager.skillUsageFailedLogCount, 1)

        let firstScanCount = await codex.scanCount
        await manager.loadSkillUsage()
        let secondScanCount = await codex.scanCount
        XCTAssertEqual(secondScanCount, firstScanCount)

        await manager.loadSkillUsage(forceRefresh: true)
        let forcedScanCount = await codex.scanCount
        XCTAssertEqual(forcedScanCount, firstScanCount + 1)
    }

    /// Preserved cache keeps old counts visible, but `preservedLogCount` records that they are
    /// stale; the manager must not downgrade this to `.failed` or hide the warning.
    @MainActor
    func testPreservedCacheStaysAvailableAndReportsStaleCounts() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: SkillUsageScanResult(
                records: [
                    "find-skills": SkillUsageRecord(
                        detectedInvocationCount: 4,
                        lastDetectedAt: nil
                    ),
                ],
                scannedLogCount: 2,
                preservedLogCount: 2,
                failedLogCount: 1
            )
        )
        let manager = SkillManager(skillUsageProviders: [codex])

        await manager.loadSkillUsage()

        XCTAssertEqual(
            manager.skillUsageScanState(for: .codex),
            .available(scannedLogCount: 2, preservedLogCount: 2, failedLogCount: 1)
        )
        XCTAssertEqual(
            manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount,
            4
        )
        XCTAssertEqual(manager.skillUsageFailedLogCount, 1)
    }
}

private actor FakeSkillUsageProvider: SkillUsageProvider {
    nonisolated let agentType: AgentType
    private let result: SkillUsageScanResult
    private(set) var scanCount = 0

    init(agentType: AgentType, result: SkillUsageScanResult) {
        self.agentType = agentType
        self.result = result
    }

    func scan() async -> SkillUsageScanResult {
        scanCount += 1
        return result
    }
}
