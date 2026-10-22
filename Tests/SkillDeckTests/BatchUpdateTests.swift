import XCTest
@testable import SkillDeck

/// Actor mock for GitServiceProtocol to verify batch update behaviors and git call counts.
actor MockGitService: GitServiceProtocol {
    var cloneCalls: [String] = []
    var cleanedDirs: [URL] = []
    var customRepoDirs: [String: URL] = [:]
    var simulatedTreeHashes: [String: String] = [:]

    func setRepoDir(_ dir: URL, for repoURL: String) {
        customRepoDirs[repoURL] = dir
    }

    func setTreeHash(_ hash: String, for path: String) {
        simulatedTreeHashes[path] = hash
    }

    func checkGitAvailable() async -> Bool { true }

    func cloneRepo(repoURL: String, shallow: Bool) async throws -> URL {
        cloneCalls.append(repoURL)
        if let custom = customRepoDirs[repoURL] {
            return custom
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func shallowClone(repoURL: String) async throws -> URL {
        try await cloneRepo(repoURL: repoURL, shallow: true)
    }

    func getCommitHash(in repoDir: URL) async throws -> String {
        "mock-commit-hash-12345"
    }

    func findCommitForTreeHash(treeHash: String, folderPath: String, in repoDir: URL) async throws -> String? {
        "mock-commit-hash-12345"
    }

    func getTreeHash(for path: String, in repoDir: URL) async throws -> String {
        simulatedTreeHashes[path] ?? "mock-tree-hash-latest"
    }

    func scanSkillsInRepo(repoDir: URL, repoURL: String?) async -> [GitService.DiscoveredSkill] {
        []
    }

    func cleanupTempDirectory(_ url: URL) async {
        cleanedDirs.append(url)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Unit tests for F19 Bulk Operations / One-Click Batch Update for skills.
@MainActor
final class BatchUpdateTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckBatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    /// Creates an isolated SkillManager whose lockfile and cache live entirely inside `tempDir`,
    /// guaranteeing zero pollution or modification to the user's ~/.agents/ directory.
    private func makeIsolatedSkillManager(gitService: any GitServiceProtocol) -> SkillManager {
        let lockURL = tempDir.appendingPathComponent(".test-skill-lock.json")
        let cacheURL = tempDir.appendingPathComponent(".test-skilldeck-cache.json")
        return SkillManager(
            gitService: gitService,
            lockFileManager: LockFileManager(filePath: lockURL),
            commitHashCache: CommitHashCache(filePath: cacheURL)
        )
    }

    private func createTestSkill(
        id: String,
        repoURL: String,
        folderPath: String,
        remoteHash: String = "remote-hash-123",
        hasUpdate: Bool = true
    ) throws -> Skill {
        let skillDir = tempDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillMD = skillDir.appendingPathComponent("SKILL.md")
        try "---\nname: \(id)\n---\nTest content".write(to: skillMD, atomically: true, encoding: .utf8)

        let skillPath = folderPath.isEmpty ? "SKILL.md" : "\(folderPath)/SKILL.md"
        let lockEntry = LockEntry(
            source: "test-owner/test-repo",
            sourceType: "github",
            sourceUrl: repoURL,
            skillPath: skillPath,
            skillFolderHash: "old-local-hash",
            installedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )

        var skill = Skill(
            id: id,
            canonicalURL: skillDir,
            metadata: SkillMetadata(name: id, description: "Description for \(id)"),
            markdownBody: "Test content",
            scope: .sharedGlobal,
            installations: []
        )
        skill.lockEntry = lockEntry
        skill.hasUpdate = hasUpdate
        skill.remoteTreeHash = hasUpdate ? remoteHash : nil
        return skill
    }

    // MARK: - Re-entrancy Guard & Auto-Check Tests

    func testReentrancy_updateAllSkillsGuardsAgainstConcurrentCheck() async {
        let mockGit = MockGitService()
        let manager = makeIsolatedSkillManager(gitService: mockGit)

        manager.isCheckingUpdates = true
        await manager.updateAllSkills()

        XCTAssertFalse(manager.isUpdatingAllSkills, "updateAllSkills should return immediately if check is already running")
    }

    func testReentrancy_checkAllUpdatesGuardsAgainstConcurrentBatchUpdate() async {
        let mockGit = MockGitService()
        let manager = makeIsolatedSkillManager(gitService: mockGit)

        manager.isUpdatingAllSkills = true
        await manager.checkAllUpdates()

        XCTAssertFalse(manager.isCheckingUpdates, "checkAllUpdates should return immediately if batch update is already running")
    }

    /// Verifies the critical path: when updateAllSkills is called without prior check,
    /// it automatically triggers checkAllUpdates() unhindered (not blocked by its own flag)
    /// and proceeds to update when updates are found.
    func testUpdateAllSkills_triggersCheckWhenPendingEmpty() async throws {
        let mockGit = MockGitService()
        let manager = makeIsolatedSkillManager(gitService: mockGit)

        let repoURL = "https://github.com/autocheck/repo.git"
        let repoDir = tempDir.appendingPathComponent("mock-autocheck-repo")
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("skills/skill-check"), withIntermediateDirectories: true)
        try "new content".write(to: repoDir.appendingPathComponent("skills/skill-check/SKILL.md"), atomically: true, encoding: .utf8)
        await mockGit.setRepoDir(repoDir, for: repoURL)
        await mockGit.setTreeHash("differing-remote-hash", for: "skills/skill-check")

        // Skill initially has hasUpdate = false and no prior check status
        let skill = try createTestSkill(id: "skill-check", repoURL: repoURL, folderPath: "skills/skill-check", hasUpdate: false)
        manager.skills = [skill]

        XCTAssertEqual(manager.updateStatuses["skill-check"], nil)

        // Calling updateAllSkills should trigger checkAllUpdates(), discover the update, and update it
        await manager.updateAllSkills()

        let cloneCalls = await mockGit.cloneCalls
        XCTAssertFalse(cloneCalls.isEmpty, "Should have performed git clone after triggering check")
        XCTAssertEqual(manager.updateStatuses["skill-check"], .upToDate, "Skill should transition to upToDate after batch update")
    }

    // MARK: - Grouping & Single Clone Tests

    func testBatchUpdate_singleClonePerRepository() async throws {
        let mockGit = MockGitService()
        let manager = makeIsolatedSkillManager(gitService: mockGit)

        let sharedRepoURL = "https://github.com/shared/repo.git"
        let otherRepoURL = "https://github.com/other/repo.git"

        // Mock repo directories with files so applySkillUpdate succeeds
        let sharedRepoDir = tempDir.appendingPathComponent("mock-shared-repo")
        try FileManager.default.createDirectory(at: sharedRepoDir.appendingPathComponent("skills/skill1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedRepoDir.appendingPathComponent("skills/skill2"), withIntermediateDirectories: true)
        try "content1".write(to: sharedRepoDir.appendingPathComponent("skills/skill1/SKILL.md"), atomically: true, encoding: .utf8)
        try "content2".write(to: sharedRepoDir.appendingPathComponent("skills/skill2/SKILL.md"), atomically: true, encoding: .utf8)
        await mockGit.setRepoDir(sharedRepoDir, for: sharedRepoURL)

        let otherRepoDir = tempDir.appendingPathComponent("mock-other-repo")
        try FileManager.default.createDirectory(at: otherRepoDir.appendingPathComponent("skills/skill3"), withIntermediateDirectories: true)
        try "content3".write(to: otherRepoDir.appendingPathComponent("skills/skill3/SKILL.md"), atomically: true, encoding: .utf8)
        await mockGit.setRepoDir(otherRepoDir, for: otherRepoURL)

        let skill1 = try createTestSkill(id: "skill1", repoURL: sharedRepoURL, folderPath: "skills/skill1")
        let skill2 = try createTestSkill(id: "skill2", repoURL: sharedRepoURL, folderPath: "skills/skill2")
        let skill3 = try createTestSkill(id: "skill3", repoURL: otherRepoURL, folderPath: "skills/skill3")

        manager.skills = [skill1, skill2, skill3]
        manager.updateStatuses["skill1"] = .hasUpdate
        manager.updateStatuses["skill2"] = .hasUpdate
        manager.updateStatuses["skill3"] = .hasUpdate

        await manager.updateAllSkills()

        let cloneCalls = await mockGit.cloneCalls
        XCTAssertEqual(cloneCalls.filter { $0 == sharedRepoURL }.count, 1, "Shared repository should only be cloned once")
        XCTAssertEqual(cloneCalls.filter { $0 == otherRepoURL }.count, 1, "Other repository should be cloned once")
        XCTAssertEqual(cloneCalls.count, 2, "Total shallow clone calls should equal number of unique repository URLs")
    }

    // MARK: - Orphan Recovery Tests

    func testOrphanRecovery_restoresMissingCanonicalDirectory() throws {
        let testDir = tempDir.appendingPathComponent("orphan-test-1")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let skillId = "restored-skill"
        let uuid = UUID().uuidString
        let orphanBackupDir = testDir.appendingPathComponent(".skilldeck-tmp-\(skillId)-\(uuid)")
        try FileManager.default.createDirectory(at: orphanBackupDir, withIntermediateDirectories: true)
        let skillMD = orphanBackupDir.appendingPathComponent("SKILL.md")
        try "recovered content".write(to: skillMD, atomically: true, encoding: .utf8)

        let canonicalDir = testDir.appendingPathComponent(skillId)
        let manifest = SkillManager.BackupManifest(skillId: skillId, canonicalPath: canonicalDir.path)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: orphanBackupDir.appendingPathComponent(".skilldeck-manifest.json"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalDir.path))

        SkillManager.recoverOrphanBackups(in: testDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.path), "Canonical directory should be restored from orphan backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent(".skilldeck-manifest.json").path), "Manifest should be removed when restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBackupDir.path), "Orphan backup directory should no longer exist after restoration")
    }

    func testOrphanRecovery_removesLeftoverWhenCanonicalExists() throws {
        let testDir = tempDir.appendingPathComponent("orphan-test-2")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let skillId = "existing-skill"
        let canonicalDir = testDir.appendingPathComponent(skillId)
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try "existing content".write(to: canonicalDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let uuid = UUID().uuidString
        let orphanBackupDir = testDir.appendingPathComponent(".skilldeck-tmp-\(skillId)-\(uuid)")
        try FileManager.default.createDirectory(at: orphanBackupDir, withIntermediateDirectories: true)
        try "backup content".write(to: orphanBackupDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let manifest = SkillManager.BackupManifest(skillId: skillId, canonicalPath: canonicalDir.path)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: orphanBackupDir.appendingPathComponent(".skilldeck-manifest.json"))

        SkillManager.recoverOrphanBackups(in: testDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.path), "Canonical directory should remain intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBackupDir.path), "Orphan backup directory should be removed when canonical directory already exists")
    }

    func testOrphanRecovery_preservesUnmanifestedBackup() throws {
        let testDir = tempDir.appendingPathComponent("orphan-test-3")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let skillId = "unmanifested-skill"
        let uuid = UUID().uuidString
        let orphanBackupDir = testDir.appendingPathComponent(".skilldeck-tmp-\(skillId)-\(uuid)")
        try FileManager.default.createDirectory(at: orphanBackupDir, withIntermediateDirectories: true)
        try "precious user files".write(to: orphanBackupDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // No manifest is present
        SkillManager.recoverOrphanBackups(in: testDir)

        // Must NOT be deleted; preserved conservatively to avoid data loss
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanBackupDir.path), "Backup without manifest must NOT be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanBackupDir.appendingPathComponent("SKILL.md").path))
    }

    // MARK: - Root-Level Skill .git Removal Test

    func testRootLevelSkill_gitFolderStrippedOnUpdate() async throws {
        let mockGit = MockGitService()
        let manager = makeIsolatedSkillManager(gitService: mockGit)

        let rootRepoURL = "https://github.com/root/skill.git"
        let repoDir = tempDir.appendingPathComponent("mock-root-repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "root skill content".write(to: repoDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Simulate .git directory in repo root
        let gitDir = repoDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        await mockGit.setRepoDir(repoDir, for: rootRepoURL)

        let rootSkill = try createTestSkill(id: "root-skill", repoURL: rootRepoURL, folderPath: "")
        manager.skills = [rootSkill]
        manager.updateStatuses["root-skill"] = .hasUpdate

        await manager.updateAllSkills()

        let canonicalGitDir = rootSkill.canonicalURL.appendingPathComponent(".git")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalGitDir.path), "Canonical directory for root-level skill must not contain .git folder")
    }
}
