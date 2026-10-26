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

    /// Dashboard scans lazily and only for the Agents in its current scope. Providers outside
    /// the requested set must stay untouched so filtering one Agent does not fan out to all.
    @MainActor
    func testLoadSkillUsageAgentTypesScansOnlySelectedProviders() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: SkillUsageScanResult(
                records: [:], scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0
            )
        )
        let claude = FakeSkillUsageProvider(
            agentType: .claudeCode,
            result: SkillUsageScanResult(
                records: [:], scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0
            )
        )
        let manager = SkillManager(skillUsageProviders: [codex, claude])

        await manager.loadSkillUsage(agentTypes: [.codex])

        let codexScanCount = await codex.scanCount
        let claudeScanCount = await claude.scanCount
        XCTAssertEqual(codexScanCount, 1)
        XCTAssertEqual(claudeScanCount, 0)
        XCTAssertEqual(
            manager.skillUsageScanState(for: .codex),
            .available(scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0)
        )
        XCTAssertEqual(manager.skillUsageScanState(for: .claudeCode), .notScanned)
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

    // MARK: - In-place refresh

    /// A forced refresh must not hide the previous snapshot or freeze/replace its state while the
    /// new scan is still running. Only the separate refresh set marks it as in flight.
    @MainActor
    func testForcedRefreshKeepsPreviousDataVisible() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: ["find-skills": record(3)], scanned: 1))
        await initial.value

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), availableState)
        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 3)
        XCTAssertFalse(manager.isRefreshingSkillUsage(.codex))

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }

        // While the refresh is suspended, everything visible must remain the old snapshot.
        XCTAssertEqual(manager.skillUsageScanState(for: .codex), availableState)
        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 3)
        XCTAssertTrue(manager.isRefreshingSkillUsage(.codex))
        XCTAssertTrue(manager.isScanningSkillUsage)

        await codex.release(result(records: ["find-skills": record(8)], scanned: 1))
        await refresh.value

        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 8)
        XCTAssertFalse(manager.isRefreshingSkillUsage(.codex))
        XCTAssertFalse(manager.isScanningSkillUsage)
    }

    /// Two callers forcing the same Agent at once must share one provider scan. This covers
    /// multiple windows and the detail page racing the Dashboard.
    @MainActor
    func testConcurrentForcedRefreshIsDeduplicated() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: [:], scanned: 1))
        await initial.value

        let first = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }

        let second = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await Task.yield()

        await codex.release(result(records: [:], scanned: 1))
        await first.value
        await second.value

        let finalScanCount = await codex.scanCount
        XCTAssertEqual(finalScanCount, 2)
    }

    /// A forced refresh is scoped to the Dashboard's current Agents only.
    @MainActor
    func testForcedRefreshScansOnlyRequestedAgents() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let claude = GatedSkillUsageProvider(agentType: .claudeCode)
        let manager = SkillManager(skillUsageProviders: [codex, claude])
        manager.skillUsageScanStates = [
            .codex: availableState,
            .claudeCode: availableState,
        ]

        let refresh = Task {
            await manager.loadSkillUsage(forceRefresh: true, agentTypes: [.codex])
        }
        await waitUntil { await codex.scanCount == 1 }

        let claudeScanCountBeforeRelease = await claude.scanCount
        XCTAssertEqual(claudeScanCountBeforeRelease, 0)

        await codex.release(result(records: [:], scanned: 1))
        await refresh.value
        let claudeScanCountAfterRelease = await claude.scanCount
        XCTAssertEqual(claudeScanCountAfterRelease, 0)
    }

    /// `forceRefresh` on a never-scanned Agent is still a first scan: it must use `.scanning`
    /// (ordering freeze/loading placeholder), not the in-place refresh set.
    @MainActor
    func testFirstScanWithForceRefreshStillUsesScanningState() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let scan = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 1 }

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .scanning)
        XCTAssertFalse(manager.isRefreshingSkillUsage(.codex))
        XCTAssertTrue(manager.isScanningSkillUsage)

        await codex.release(result(records: [:], scanned: 1))
        await scan.value
        XCTAssertEqual(manager.skillUsageScanState(for: .codex), availableState)
    }

    // MARK: - Automatic refresh reservation

    /// Reservation is a synchronous main-actor critical section: the first caller wins and writes
    /// the timestamp; a second caller with the same `now` sees a zero interval and is throttled.
    @MainActor
    func testAutomaticRefreshReservationIsAtomic() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: result(records: [:], scanned: 1)
        )
        let manager = SkillManager(skillUsageProviders: [codex])
        await manager.loadSkillUsage()

        let now = Date().addingTimeInterval(3600)
        let first = manager.reserveAutomaticSkillUsageRefresh(
            agentTypes: [.codex],
            minimumInterval: 300,
            now: now
        )
        let second = manager.reserveAutomaticSkillUsageRefresh(
            agentTypes: [.codex],
            minimumInterval: 300,
            now: now
        )

        XCTAssertEqual(first, [.codex])
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(manager.skillUsageLastScanAttemptDate(for: .codex), now)
    }

    /// Regression for multiple windows: even if the first reserved scan finishes before the
    /// second window calls in, the reservation timestamp still blocks the second trigger.
    @MainActor
    func testAutomaticRefreshReservationBlocksAfterFastCompletion() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: result(records: [:], scanned: 1)
        )
        let manager = SkillManager(skillUsageProviders: [codex])
        await manager.loadSkillUsage()

        let now = Date().addingTimeInterval(3600)
        let reserved = manager.reserveAutomaticSkillUsageRefresh(
            agentTypes: [.codex],
            minimumInterval: 300,
            now: now
        )
        XCTAssertEqual(reserved, [.codex])

        await manager.loadSkillUsage(forceRefresh: true, agentTypes: reserved)

        let after = manager.reserveAutomaticSkillUsageRefresh(
            agentTypes: [.codex],
            minimumInterval: 300,
            now: now
        )
        XCTAssertTrue(after.isEmpty)
    }

    /// Manual refresh ignores the throttle but still refreshes the attempt timestamp, so the next
    /// automatic activation does not immediately scan again.
    @MainActor
    func testManualRefreshBypassesReservationThrottle() async {
        let codex = FakeSkillUsageProvider(
            agentType: .codex,
            result: result(records: [:], scanned: 1)
        )
        let manager = SkillManager(skillUsageProviders: [codex])

        await manager.loadSkillUsage()
        let initialCount = await codex.scanCount

        // Called immediately after the first scan: the throttle must not apply to manual refresh.
        await manager.loadSkillUsage(forceRefresh: true)
        let forcedScanCount = await codex.scanCount
        XCTAssertEqual(forcedScanCount, initialCount + 1)

        let lastAttempt = try? XCTUnwrap(manager.skillUsageLastScanAttemptDate(for: .codex))
        let reserved = manager.reserveAutomaticSkillUsageRefresh(
            agentTypes: [.codex],
            minimumInterval: 300,
            now: lastAttempt ?? Date()
        )
        XCTAssertTrue(reserved.isEmpty)
    }

    // MARK: - Stale preservation

    /// When every log is unreadable but a readable snapshot exists, keep the records and mark the
    /// Agent stale so the UI can show a warning instead of dropping to zero/unknown.
    @MainActor
    func testTotalRefreshFailureKeepsPreviousRecordsAsStale() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: ["find-skills": record(5)], scanned: 2))
        await initial.value

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }
        await codex.release(result(records: [:], scanned: 0, failed: 2))
        await refresh.value

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .stale(failedLogCount: 2))
        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 5)
        XCTAssertEqual(manager.skillUsageFailedLogCount, 2)
    }

    /// A failed first scan has no trustworthy snapshot; a later failed refresh must stay `.failed`
    /// rather than pretending stale data exists.
    @MainActor
    func testTotalRefreshFailureWithoutPreviousDataStaysFailed() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: [:], scanned: 0, failed: 1))
        await initial.value
        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .failed(failedLogCount: 1))

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }
        await codex.release(result(records: [:], scanned: 0, failed: 3))
        await refresh.value

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .failed(failedLogCount: 3))
        XCTAssertEqual(manager.skillUsageFailedLogCount, 3)
    }

    /// A deleted history source is not a read failure: counts must be cleared and the state must
    /// become `.unavailable`, not `.stale`.
    @MainActor
    func testRefreshWithNoSourceClearsRecordsAndBecomesUnavailable() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: ["find-skills": record(5)], scanned: 2))
        await initial.value

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }
        await codex.release(result(records: [:], scanned: 0, failed: 0))
        await refresh.value

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .unavailable)
        XCTAssertNil(manager.skillUsage(for: "find-skills", agent: .codex))
    }

    // MARK: - Cancellation

    /// Cancellation is cooperative and delayed: the group must drain first. Until then the spinner
    /// and refresh markers stay; afterwards results are discarded and markers are cleared.
    @MainActor
    func testCanceledRefreshWaitsForGroupDrainThenClearsState() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: ["find-skills": record(3)], scanned: 1))
        await initial.value

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }
        refresh.cancel()

        // Providers perform synchronous I/O and do not observe cancellation, so the in-flight
        // markers must survive until the scan group drains.
        XCTAssertTrue(manager.isRefreshingSkillUsage(.codex))
        XCTAssertTrue(manager.isScanningSkillUsage)

        await codex.release(result(records: ["find-skills": record(9)], scanned: 1))
        await refresh.value

        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 3)
        XCTAssertFalse(manager.isRefreshingSkillUsage(.codex))
        XCTAssertFalse(manager.isScanningSkillUsage)
    }

    /// A cancelled first scan must return to `.notScanned` once the group drains, otherwise the
    /// lazy Dashboard scan could never retry and the spinner would stick forever.
    @MainActor
    func testCanceledInitialScanWaitsThenRevertsToNotScanned() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let scan = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        scan.cancel()

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .scanning)
        XCTAssertTrue(manager.isScanningSkillUsage)

        await codex.release(result(records: [:], scanned: 1))
        await scan.value

        XCTAssertEqual(manager.skillUsageScanState(for: .codex), .notScanned)
        XCTAssertFalse(manager.isScanningSkillUsage)

        // The Agent is retryable after the cancelled attempt drains.
        let retry = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 2 }
        await codex.release(result(records: [:], scanned: 1))
        await retry.value
        XCTAssertEqual(manager.skillUsageScanState(for: .codex), availableState)
    }

    /// Even if a cancelled scan finishes with newer data, its late result must not be applied.
    @MainActor
    func testCancellationDiscardsLateResults() async {
        let codex = GatedSkillUsageProvider(agentType: .codex)
        let manager = SkillManager(skillUsageProviders: [codex])

        let initial = Task { await manager.loadSkillUsage() }
        await waitUntil { await codex.scanCount == 1 }
        await codex.release(result(records: ["find-skills": record(3)], scanned: 1))
        await initial.value

        let refresh = Task { await manager.loadSkillUsage(forceRefresh: true) }
        await waitUntil { await codex.scanCount == 2 }
        refresh.cancel()
        await codex.release(result(records: ["find-skills": record(11)], scanned: 1))
        await refresh.value

        XCTAssertEqual(manager.skillUsage(for: "find-skills", agent: .codex)?.detectedInvocationCount, 3)
        XCTAssertEqual(manager.skillUsageScanState(for: .codex), availableState)
    }

    // MARK: - Fixtures

    private var availableState: SkillUsageScanState {
        .available(scannedLogCount: 1, preservedLogCount: 0, failedLogCount: 0)
    }

    private func record(_ count: Int) -> SkillUsageRecord {
        SkillUsageRecord(detectedInvocationCount: count, lastDetectedAt: nil)
    }

    private func result(
        records: [String: SkillUsageRecord],
        scanned: Int,
        preserved: Int = 0,
        failed: Int = 0
    ) -> SkillUsageScanResult {
        SkillUsageScanResult(
            records: records,
            scannedLogCount: scanned,
            preservedLogCount: preserved,
            failedLogCount: failed
        )
    }

    /// Polls the provider's actor-isolated counter instead of sleeping for a fixed duration, so
    /// the tests stay deterministic while the scan task is suspended on its continuation.
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

/// Models production providers, which perform synchronous file I/O and do NOT observe
/// cancellation. A scan finishes only when the test explicitly releases it, so tests can assert
/// that cleanup happens after the task group drains rather than immediately on cancel.
///
/// Do not add `withTaskCancellationHandler` here: that would hide the real provider behavior the
/// cancellation tests are meant to document.
private actor GatedSkillUsageProvider: SkillUsageProvider {
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
