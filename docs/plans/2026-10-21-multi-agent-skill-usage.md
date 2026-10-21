# Multi-Agent Skill Usage Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Codex、CodeBuddy、Qoder、OpenCode 统一统计本地历史中的 skill 调用次数，并把次数直接展示在 Skill 详情页的每个 Agent Assignment 行内。

**Architecture:** 新增 `SkillUsageProvider` 协议，每种 Agent 一个 `actor` 适配器。JSONL 类历史（Codex/CodeBuddy/Qoder）复用带增量缓存的扫描器；OpenCode 2.x 直接只读查询 SQLite。`SkillManager` 汇总所有 provider 的结果，UI 只读取 `[AgentType: [SkillID: SkillUsageRecord]]`，不再维护 Codex 专用状态。

**Tech Stack:** Swift 5.9、SwiftUI（macOS 14+）、XCTest、SQLite3（系统模块）、FileManager、JSONSerialization。

> **提交约定:** 本计划不包含自动 `git add` / `git commit` 步骤。每个 Task 完成后保留工作区改动，由实施者在评审后按仓库约定提交。禁止使用 `git add -A`：工作区可能已有本地未跟踪的 `.qoder/`，且本计划文件本身也不应被自动暂存。

---

## 1. 已确认的数据源

| Agent | 版本/格式 | 位置 | 识别字段 | 成功判定 |
|---|---|---|---|---|
| Codex | JSONL | `~/.codex/sessions/**/*.jsonl`、`~/.codex/archived_sessions/**/*.jsonl` | `response_item` + `custom_tool_call`/`function_call`，工具参数引用可信 `SKILL.md` 路径 | 启发式，无法区分成功/失败 |
| CodeBuddy | JSONL | `~/.codebuddy/projects/**/*.jsonl` | `type == "function_call_result"`、`name == "Skill"`、`status == "completed"`、`output.text` 以 `Base directory for this skill: ` 开头 | 精确，只计 completed |
| Qoder | JSONL | `~/.qoder/projects/**/*.jsonl` | `type == "system"` 且 `content == "Skill **<name>** activated."` | 精确，只计激活成功 |
| OpenCode 2.x | SQLite | `~/.local/share/opencode/opencode.db`，表 `part` | `json_extract(data,'$.tool') == "skill"`，名称在 `$.state.input.name`，状态在 `$.state.status` | 精确，只计 completed |

本机验证结果（实施后可用于人工核对）：

- CodeBuddy：`gzh-design` 2 次。
- Qoder：`skilldeck` 1 次（2026-10-21 的 `/skilldeck` 会话）。
- OpenCode 2.0.29：`web-access` 10 次、`gzh-design` 2 次、`agent-notifier` 2 次等，共 18 次 completed、1 次 error。
- OpenCode `part` 表本机约 24,276 行、`data` 总计约 61 MB；全量扫描可接受，不需要磁盘缓存。

明确不做：

- OpenCode 1.x 的 `storage/part/*.json`，只支持 2.x SQLite。
- Claude Code、Gemini CLI 等其他 Agent 的 usage 统计。
- 用项目仓库里的 `SKILL.md` 路径推断调用（误报太多）。
- 独立的 Usage 区块；全部收进 Agent Assignment 行内。

---

## 2. 验收标准

1. 打开任意 Skill 详情页，Agent Assignment 列表中的 Codex、CodeBuddy、Qoder、OpenCode 四行会在名称下方显示检测到的调用次数；其余 Agent 不显示 usage 文本。
2. 次数为 0 时不显示「0 次」，只显示「未检测到本地使用」；历史源存在但全部读取失败且没有可用缓存时显示「本地历史无法读取」，不得显示成「未检测到使用」或「无本地历史」；有上次缓存时行内仍显示旧次数，同时显示橙色警告；尚未扫描时不显示任何 usage 状态，只在区块标题旁显示「扫描历史」。
3. 扫描中标题旁显示进度；有历史文件或目录读取失败时显示橙色警告图标；`preservedLogCount > 0` 的行内计数旁也显示警告图标；扫描完成后显示刷新按钮。
4. Toggle（是否分配）与 usage（历史调用）完全独立：关闭 Toggle 不影响已检测到的次数。
5. `swift test` 全绿，`swift build` 成功，`swift run SkillDeck` 可启动并人工看到四类 Agent 的次数。
6. `L10nKeysCoverageTests` 通过（en / zh-Hans 都包含新增 key）。

---

## 3. 文件结构

**新增**

- `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`：`SkillUsageProvider` 协议；默认 provider 工厂在 Task 5 追加。
- `Sources/SkillDeck/Services/SkillUsage/SkillUsageLogCache.swift`：JSONL 类 provider 共用的文件指纹缓存。
- `Sources/SkillDeck/Services/SkillUsage/SkillUsageLineReader.swift`：按固定大小分块逐行读取 UTF-8 日志，避免整文件载入内存。
- `Sources/SkillDeck/Services/SkillUsage/SkillUsageJSONLScanner.swift`：通用 JSONL 扫描、增量缓存、聚合、目录枚举失败统计。
- `Sources/SkillDeck/Services/SkillUsage/CodeBuddySkillUsageService.swift`
- `Sources/SkillDeck/Services/SkillUsage/QoderSkillUsageService.swift`
- `Sources/SkillDeck/Services/SkillUsage/OpenCodeSkillUsageService.swift`
- `Tests/SkillDeckTests/SkillUsageJSONLScannerTests.swift`
- `Tests/SkillDeckTests/CodeBuddySkillUsageServiceTests.swift`
- `Tests/SkillDeckTests/QoderSkillUsageServiceTests.swift`
- `Tests/SkillDeckTests/OpenCodeSkillUsageServiceTests.swift`
- `Tests/SkillDeckTests/SkillManagerUsageTests.swift`

**移动并修改**

- `Sources/SkillDeck/Services/CodexSkillUsageService.swift`
  → `Sources/SkillDeck/Services/SkillUsage/CodexSkillUsageService.swift`

**修改**

- `Sources/SkillDeck/Models/SkillUsage.swift`
- `Sources/SkillDeck/Models/AgentType.swift`
- `Sources/SkillDeck/Services/SkillManager.swift`
- `Sources/SkillDeck/Views/Components/AgentToggleView.swift`
- `Sources/SkillDeck/Views/Detail/SkillDetailView.swift`
- `Sources/SkillDeck/Utilities/Localization/L10nKeys.swift`
- `Sources/SkillDeck/Resources/Localizations/en.lproj/Localizable.strings`
- `Sources/SkillDeck/Resources/Localizations/zh-Hans.lproj/Localizable.strings`

**不改**

- `Package.swift`。已在本机验证 `import SQLite3` 可编译、可链接，无需新增 target 或 linkerSettings。

---

## 4. 共享语义

- `SkillUsageRecord.detectedInvocationCount` 表示「在可读取的本地历史中检测到的成功调用次数」，不是绝对总数。
- `SkillUsageScanState` 改为每个 Agent 一份：
  - `.notScanned`：本次启动尚未扫描。
  - `.scanning`：正在扫描。
  - `.available(scannedLogCount:preservedLogCount:failedLogCount:)`：至少有一个历史文件为索引贡献了记录；即使 0 次调用也算 available。`scannedLogCount` 包含本次成功读取、文件指纹命中缓存，以及从上次缓存保留的文件；其中 `preservedLogCount` 是「本次无法读取、只能用上次缓存」的子集，这些次数可能过期。`failedLogCount > 0` 表示部分文件或目录枚举失败。OpenCode 的 `scannedLogCount` 在数据库可读时固定为 1，且 `preservedLogCount` 恒为 0。
  - `.failed(failedLogCount:)`：历史源存在（目录、文件或数据库），但全部无法读取且没有可用缓存。此状态不能显示成「未检测到使用」或「无本地历史」。
  - `.unavailable`：历史源确实不存在（目录或数据库缺失），不是读取失败。权限不足导致无法确认路径是否存在时，必须算作读取失败而不是 unavailable。
  - UI 预期：`preservedLogCount > 0` 时，行内仍显示上次缓存的次数，同时显示橙色警告；全部记录都来自缓存时也不能显示成「未检测到使用」。
- 普通 `loadSkillUsage()` 只扫描 `.notScanned` 的 provider；`.available`、`.failed`、`.unavailable` 都复用内存结果。
- `loadSkillUsage(forceRefresh: true)` 重扫全部 provider。
- 失败的文件保留上一次缓存结果（若存在），并计入 `failedLogCount`。目录枚举失败时无法确认哪些文件已被删除，因此保留受影响目录下已有的缓存条目；同样计入 `failedLogCount`，既不会伪装成「没有历史」，也不会让旧计数突然消失。`failedLogCount` 同时统计文件读取失败和目录枚举失败。

---

## Task 0: 分支与基线

**Files:** 无

- [ ] **Step 1: 更新 main 并创建功能分支**

Run:

```bash
git switch main
git pull --ff-only
git switch -c feature/multi-agent-skill-usage
git status --short
```

Expected: 当前位于 `feature/multi-agent-skill-usage`；除实施前已存在的未跟踪 `.qoder/` 和本计划文件外，没有意外改动。

- [ ] **Step 2: 运行全量测试**

Run:

```bash
swift test
```

Expected:

```text
Executed ... tests, with 0 failures
```

- [ ] **Step 3: 运行构建**

Run:

```bash
swift build
```

Expected: `Build complete!`

---

## Task 1: 共享 Provider 基础设施 + Codex 适配

**Files:**

- Modify: `Sources/SkillDeck/Models/SkillUsage.swift`
- Modify: `Sources/SkillDeck/Models/AgentType.swift`
- Create: `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`
- Create: `Sources/SkillDeck/Services/SkillUsage/SkillUsageLogCache.swift`
- Create: `Sources/SkillDeck/Services/SkillUsage/SkillUsageLineReader.swift`
- Create: `Sources/SkillDeck/Services/SkillUsage/SkillUsageJSONLScanner.swift`
- Create: `Tests/SkillDeckTests/SkillUsageJSONLScannerTests.swift`
- Move: `Sources/SkillDeck/Services/CodexSkillUsageService.swift` → `Sources/SkillDeck/Services/SkillUsage/CodexSkillUsageService.swift`
- Test: `Tests/SkillDeckTests/CodexSkillUsageServiceTests.swift`（现有测试，不修改断言）

- [ ] **Step 1: 给模型加 Sendable 和事件类型**

把 `Sources/SkillDeck/Models/SkillUsage.swift` 中的三个声明改成：

```swift
struct SkillUsageRecord: Codable, Equatable, Sendable {
    let detectedInvocationCount: Int
    let lastDetectedAt: Date?
}

enum SkillUsageScanState: Equatable, Sendable {
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

struct SkillUsageScanResult: Equatable, Sendable {
    let records: [String: SkillUsageRecord]
    /// Files contributing records: read now, fingerprint cache hit, or preserved from cache.
    let scannedLogCount: Int
    /// Subset of `scannedLogCount` restored only because this scan could not read the file.
    /// These counts may be stale and must not be presented as freshly observed.
    let preservedLogCount: Int
    let failedLogCount: Int
}
```

在 `SkillUsageScanResult` 后面追加：

```swift
/// One detected invocation recovered from a single history record.
struct SkillUsageEvent: Equatable, Sendable {
    let skillID: String
    let timestamp: Date?
}
```

把 `Sources/SkillDeck/Models/AgentType.swift` 第 5 行改为：

```swift
enum AgentType: String, CaseIterable, Identifiable, Codable, Sendable {
```

- [ ] **Step 2: 新增 Provider 协议**

Create `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`:

```swift
import Darwin
import Foundation

/// One Agent-specific adapter that recovers best-effort skill usage from local history.
protocol SkillUsageProvider: Sendable {
    /// Agent whose local history this provider reads.
    var agentType: AgentType { get }

    /// Scan the provider's local history and return one complete index.
    func scan() async -> SkillUsageScanResult
}

/// Result of inspecting a configured history path.
enum SkillUsagePathStatus: Equatable, Sendable {
    case directory
    case notDirectory
    case missing
    case inaccessible
}

/// Inspects a history path without collapsing permission errors into "not found".
///
/// `FileManager.fileExists` returns `false` for both a missing path and an unreadable parent,
/// which would incorrectly turn a permission problem into `.unavailable`.
enum SkillUsagePathProbe {
    static func status(at url: URL) -> SkillUsagePathStatus {
        var info = stat()
        // `fstatat` follows symlinks like `stat`, but avoids the `stat` struct/function name
        // collision in Swift. `AT_FDCWD` resolves a relative path against the current directory.
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else {
            // ENOENT/ENOTDIR mean the path truly does not exist. EACCES and other errors mean
            // it may exist but cannot be verified, so callers must report a read failure.
            switch errno {
            case ENOENT, ENOTDIR:
                return .missing
            default:
                return .inaccessible
            }
        }
        return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .notDirectory
    }
}
```

说明：默认工厂需要引用四个 provider，因此在 Task 5（四个 service 都存在后）再添加，避免 Task 1 因找不到类型而无法编译。

- [ ] **Step 3: 新增共享缓存类型**

Create `Sources/SkillDeck/Services/SkillUsage/SkillUsageLogCache.swift`:

```swift
import Foundation

struct SkillUsageLogFingerprint: Codable, Equatable, Sendable {
    let fileSize: UInt64
    let modificationDate: Date
}

struct SkillUsageCachedLog: Codable, Sendable {
    let fingerprint: SkillUsageLogFingerprint
    let records: [String: SkillUsageRecord]
}

struct SkillUsageLogCache: Codable, Sendable {
    /// Increment when the cache shape or matching semantics change.
    static let currentVersion = 3

    var version: Int
    var files: [String: SkillUsageCachedLog]

    init(
        version: Int = SkillUsageLogCache.currentVersion,
        files: [String: SkillUsageCachedLog] = [:]
    ) {
        self.version = version
        self.files = files
    }

    static func load(from url: URL?) -> SkillUsageLogCache {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SkillUsageLogCache.self, from: data),
              decoded.version == currentVersion else {
            return SkillUsageLogCache()
        }
        return decoded
    }

    func save(to url: URL?, fileManager: FileManager = .default) {
        guard let url else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            // Usage remains available in memory even when cache persistence is not permitted.
        }
    }
}

/// Mutable accumulator shared by all JSONL providers.
struct MutableSkillUsageRecord {
    var detectedInvocationCount = 0
    var lastDetectedAt: Date?
}
```

- [ ] **Step 4: 新增时间戳解析器**

把下面代码追加到 `SkillUsageLogCache.swift` 末尾：

```swift
enum SkillUsageTimestampParser {
    /// Codex and Qoder timestamps are ISO-8601 and commonly include fractional seconds.
    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }

    /// CodeBuddy timestamps are Unix milliseconds.
    static func parseMilliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}
```

- [ ] **Step 5: 写扫描器失败语义测试**

Create `Tests/SkillDeckTests/SkillUsageJSONLScannerTests.swift`:

```swift
import Darwin
import Foundation
import XCTest

@testable import SkillDeck

/// Covers failure reporting, cache preservation, and bounded-memory line reading.
final class SkillUsageJSONLScannerTests: XCTestCase {
    func testUnreadableLogIsReportedAsFailure() throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let logURL = projects.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: logURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: logURL.path
            )
        }

        let result = makeScanner(directories: [projects], fixture: fixture).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testUnreadableHistoryDirectoryIsReportedAsFailure() throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: projects.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: projects.path
            )
        }

        let result = makeScanner(directories: [projects], fixture: fixture).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
    }

    /// A failed enumeration must not erase the last known counts for that directory.
    func testEnumerationFailureKeepsCachedCounts() throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let logURL = projects.appendingPathComponent("session.jsonl")
        try "{\"skill\":\"cached-skill\"}\n".write(to: logURL, atomically: true, encoding: .utf8)

        let scanner = SkillUsageJSONLScanner(
            directories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json"),
            fileManager: .default,
            parse: { line in
                line.contains("cached-skill")
                    ? [SkillUsageEvent(skillID: "cached-skill", timestamp: nil)]
                    : []
            }
        )

        let first = scanner.scan()
        XCTAssertEqual(first.scannedLogCount, 1)
        XCTAssertEqual(first.preservedLogCount, 0)
        XCTAssertEqual(first.failedLogCount, 0)
        XCTAssertEqual(first.records["cached-skill"]?.detectedInvocationCount, 1)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: projects.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: projects.path
            )
        }

        let second = scanner.scan()

        XCTAssertEqual(second.failedLogCount, 1)
        XCTAssertEqual(second.scannedLogCount, 1)
        XCTAssertEqual(second.preservedLogCount, 1)
        XCTAssertEqual(second.records["cached-skill"]?.detectedInvocationCount, 1)
    }

    /// An unreadable parent makes the history path impossible to verify, which is a failure
    /// rather than "the Agent is not installed".
    func testInaccessibleHistoryParentIsReportedAsFailure() throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let agentDirectory = fixture.root.appendingPathComponent("agent", isDirectory: true)
        let historyDirectory = agentDirectory.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: agentDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: agentDirectory.path
            )
        }

        let result = makeScanner(directories: [historyDirectory], fixture: fixture).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
    }

    /// A line larger than the 64 KB read chunk must still be parsed exactly once.
    func testReadsLinesAcrossChunkBoundaries() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let logURL = projects.appendingPathComponent("session.jsonl")

        let longLine = String(repeating: "x", count: 200_000)
        try (longLine + "\n" + longLine + "\n").write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )

        let scanner = SkillUsageJSONLScanner(
            directories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json"),
            fileManager: .default,
            parse: { line in
                line.count == 200_000
                    ? [SkillUsageEvent(skillID: "long-line", timestamp: nil)]
                    : []
            }
        )

        let result = scanner.scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.records["long-line"]?.detectedInvocationCount, 2)
    }

    private func makeScanner(
        directories: [URL],
        fixture: TemporaryFixture
    ) -> SkillUsageJSONLScanner {
        SkillUsageJSONLScanner(
            directories: directories,
            cacheURL: fixture.root.appendingPathComponent("cache.json"),
            fileManager: .default,
            parse: { _ in [] }
        )
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckJSONLScannerTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

- [ ] **Step 6: 运行测试确认失败**

Run:

```bash
swift test --filter SkillUsageJSONLScannerTests
```

Expected: 编译失败，提示 `cannot find 'SkillUsageJSONLScanner' in scope`。

- [ ] **Step 7: 新增流式行读取器**

Create `Sources/SkillDeck/Services/SkillUsage/SkillUsageLineReader.swift`:

```swift
import Foundation

enum SkillUsageLineReaderError: Error {
    case invalidUTF8
}

/// Reads a log incrementally so a large history file never has to fit in memory.
///
/// `String(contentsOf:)` would allocate the entire file. This reader keeps only the current
/// 64 KB chunk plus the unfinished line, which bounds memory by the longest single JSONL line.
enum SkillUsageLineReader {
    static func forEachLine(
        at url: URL,
        chunkSize: Int = 64 * 1024,
        _ body: (String) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let lineData = buffer[lineStart..<newline]
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw SkillUsageLineReaderError.invalidUTF8
                }
                body(line)
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if !buffer.isEmpty {
            guard let line = String(data: buffer, encoding: .utf8) else {
                throw SkillUsageLineReaderError.invalidUTF8
            }
            body(line)
        }
    }
}
```

- [ ] **Step 8: 新增通用 JSONL 扫描器**

Create `Sources/SkillDeck/Services/SkillUsage/SkillUsageJSONLScanner.swift`:

```swift
import Darwin
import Foundation

/// Result of enumerating one provider's history directories.
struct SkillUsageLogEnumeration {
    let urls: [URL]
    let failedSourceCount: Int
    /// Directories whose contents may be incomplete. Cached files under them must be preserved
    /// because a missing URL cannot be distinguished from a file hidden by a read error.
    let failedDirectories: [URL]
}

/// Enumerates JSONL files and reports sources that exist but cannot be read.
///
/// A missing directory means the Agent is simply not installed, so it is not a failure.
/// An existing path that is not an enumerable directory, or an enumeration error, is a failure.
enum SkillUsageLogEnumerator {
    static func enumerate(
        directories: [URL],
        fileManager: FileManager
    ) -> SkillUsageLogEnumeration {
        var result: [URL] = []
        var failedSourceCount = 0
        var failedDirectories: [URL] = []

        for directory in directories {
            switch SkillUsagePathProbe.status(at: directory) {
            case .missing:
                // The Agent is simply not installed; this is not a read failure.
                continue
            case .notDirectory, .inaccessible:
                // Existing non-directory paths and permission errors both mean the configured
                // history root cannot be used, so they must be visible as failures.
                failedSourceCount += 1
                failedDirectories.append(directory)
                continue
            case .directory:
                break
            }

            var enumerationErrorCount = 0
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationErrorCount += 1
                    return true
                }
            ) else {
                failedSourceCount += 1
                failedDirectories.append(directory)
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                result.append(fileURL)
            }
            if enumerationErrorCount > 0 {
                failedSourceCount += enumerationErrorCount
                failedDirectories.append(directory)
            }
        }

        return SkillUsageLogEnumeration(
            urls: result.sorted { $0.path < $1.path },
            failedSourceCount: failedSourceCount,
            failedDirectories: failedDirectories
        )
    }
}

/// Canonical path used to relate cached files to a failed history directory.
///
/// `realpath` resolves `/var` to `/private/var`, matching the URLs returned by
/// `FileManager.enumerator`. When the final component cannot be read, resolve its parent
/// instead so a permission error does not prevent cache preservation.
private func canonicalUsagePath(_ url: URL) -> String {
    if let resolved = realpath(url.path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }

    let parent = url.deletingLastPathComponent()
    if let resolvedParent = realpath(parent.path, nil) {
        defer { free(resolvedParent) }
        return URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
            .path
    }

    return url.standardizedFileURL.path
}

extension SkillUsageLogEnumeration {
    /// Cache entries belonging to directories whose enumeration failed.
    func cachedFilesToPreserve(from cache: SkillUsageLogCache) -> [String: SkillUsageCachedLog] {
        let prefixes = failedDirectories.map { directory -> String in
            let path = canonicalUsagePath(directory)
            return path.hasSuffix("/") ? path : path + "/"
        }
        guard !prefixes.isEmpty else { return [:] }

        var preserved: [String: SkillUsageCachedLog] = [:]
        for (path, cached) in cache.files {
            let fileURL = URL(fileURLWithPath: path)
            let candidates = [
                canonicalUsagePath(fileURL),
                fileURL.standardizedFileURL.path,
            ]
            if prefixes.contains(where: { prefix in
                candidates.contains { $0.hasPrefix(prefix) }
            }) {
                preserved[path] = cached
            }
        }
        return preserved
    }
}

/// Enumerates JSONL history files, reuses cached per-file results, and aggregates by skill ID.
struct SkillUsageJSONLScanner {
    let directories: [URL]
    let cacheURL: URL?
    let fileManager: FileManager
    let parse: @Sendable (String) -> [SkillUsageEvent]

    func scan() -> SkillUsageScanResult {
        var cache = SkillUsageLogCache.load(from: cacheURL)
        var refreshedFiles: [String: SkillUsageCachedLog] = [:]
        var failedLogPaths: Set<String> = []
        var preservedLogPaths: Set<String> = []

        let enumeration = SkillUsageLogEnumerator.enumerate(
            directories: directories,
            fileManager: fileManager
        )
        for url in enumeration.urls {
            guard let fingerprint = fingerprint(for: url) else {
                failedLogPaths.insert(url.path)
                if let cached = cache.files[url.path] {
                    refreshedFiles[url.path] = cached
                    preservedLogPaths.insert(url.path)
                }
                continue
            }

            if let cached = cache.files[url.path], cached.fingerprint == fingerprint {
                refreshedFiles[url.path] = cached
                continue
            }

            var records: [String: MutableSkillUsageRecord] = [:]
            do {
                try SkillUsageLineReader.forEachLine(at: url) { line in
                    for event in parse(line) {
                        var record = records[event.skillID] ?? MutableSkillUsageRecord()
                        record.detectedInvocationCount += 1
                        if let timestamp = event.timestamp,
                           record.lastDetectedAt == nil || timestamp > record.lastDetectedAt! {
                            record.lastDetectedAt = timestamp
                        }
                        records[event.skillID] = record
                    }
                }
            } catch {
                failedLogPaths.insert(url.path)
                if let cached = cache.files[url.path] {
                    refreshedFiles[url.path] = cached
                    preservedLogPaths.insert(url.path)
                }
                continue
            }

            refreshedFiles[url.path] = SkillUsageCachedLog(
                fingerprint: fingerprint,
                records: records.mapValues {
                    SkillUsageRecord(
                        detectedInvocationCount: $0.detectedInvocationCount,
                        lastDetectedAt: $0.lastDetectedAt
                    )
                }
            )
        }

        // An enumeration error hides files, so their absence from `refreshedFiles` is not proof
        // that they were deleted. Keep the last known counts for the affected directories until
        // a later scan can enumerate them successfully.
        let preservedFiles = enumeration.cachedFilesToPreserve(from: cache)
        for (path, cached) in preservedFiles where refreshedFiles[path] == nil {
            refreshedFiles[path] = cached
            preservedLogPaths.insert(path)
        }

        cache.files = refreshedFiles
        cache.save(to: cacheURL, fileManager: fileManager)

        var merged: [String: MutableSkillUsageRecord] = [:]
        for file in refreshedFiles.values {
            for (skillID, record) in file.records {
                var aggregate = merged[skillID] ?? MutableSkillUsageRecord()
                aggregate.detectedInvocationCount += record.detectedInvocationCount
                if let timestamp = record.lastDetectedAt,
                   aggregate.lastDetectedAt == nil || timestamp > aggregate.lastDetectedAt! {
                    aggregate.lastDetectedAt = timestamp
                }
                merged[skillID] = aggregate
            }
        }

        return SkillUsageScanResult(
            records: merged.mapValues {
                SkillUsageRecord(
                    detectedInvocationCount: $0.detectedInvocationCount,
                    lastDetectedAt: $0.lastDetectedAt
                )
            },
            scannedLogCount: refreshedFiles.count,
            preservedLogCount: preservedLogPaths.count,
            failedLogCount: enumeration.failedSourceCount + failedLogPaths.count
        )
    }

    private func fingerprint(for url: URL) -> SkillUsageLogFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        return SkillUsageLogFingerprint(
            fileSize: UInt64(fileSize),
            modificationDate: modificationDate
        )
    }
}
```

- [ ] **Step 9: 运行扫描器测试确认通过**

Run:

```bash
swift test --filter SkillUsageJSONLScannerTests
```

Expected:

```text
Executed 5 tests, with 0 failures
```

- [ ] **Step 10: 移动 Codex 服务文件**

Run:

```bash
mkdir -p Sources/SkillDeck/Services/SkillUsage
git mv Sources/SkillDeck/Services/CodexSkillUsageService.swift Sources/SkillDeck/Services/SkillUsage/CodexSkillUsageService.swift
```

- [ ] **Step 11: 让 Codex 服务实现协议并复用共享缓存**

在 `Sources/SkillDeck/Services/SkillUsage/CodexSkillUsageService.swift` 中按下列内容修改。

把 actor 声明：

```swift
actor CodexSkillUsageService {
```

改成：

```swift
actor CodexSkillUsageService: SkillUsageProvider {
    /// Agent whose local history this adapter reads.
    nonisolated var agentType: AgentType { .codex }
```

删除：

```swift
    /// Increment when the persisted cache schema or matching semantics change.
    private static let cacheVersion = 2
```

做以下类型重命名（全文件替换）：

```text
CachedLogResult              -> SkillUsageCachedLog
LogFingerprint               -> SkillUsageLogFingerprint
UsageCache                   -> SkillUsageLogCache
MutableUsageRecord           -> MutableSkillUsageRecord
```

把 `scan()` 顶部的文件枚举：

```swift
        for logURL in historyLogURLs() {
```

替换为：

```swift
        let enumeration = SkillUsageLogEnumerator.enumerate(
            directories: historyDirectories,
            fileManager: fileManager
        )
        for logURL in enumeration.urls {
```

在 `var failedLogPaths: Set<String> = []` 之后追加：

```swift
        // Files whose counts come only from the previous scan because this run failed to read them.
        var preservedLogPaths: Set<String> = []
```

把初始指纹检查失败的分支：

```swift
            guard let fingerprint = fingerprint(for: logURL) else {
                failedLogPaths.insert(logURL.path)
                if let cached = cache.files[logURL.path] {
                    refreshedFiles[logURL.path] = cached
                }
                continue
            }
```

替换为：

```swift
            guard let fingerprint = fingerprint(for: logURL) else {
                failedLogPaths.insert(logURL.path)
                if let cached = cache.files[logURL.path] {
                    refreshedFiles[logURL.path] = cached
                    preservedLogPaths.insert(logURL.path)
                }
                continue
            }
```

把失败文件回填缓存的分支：

```swift
        for path in scannedChanges.failedPaths {
            // Keep the old fingerprint so a later refresh retries the failed file.
            if let cached = cache.files[path] {
                refreshedFiles[path] = cached
            }
        }
```

替换为：

```swift
        for path in scannedChanges.failedPaths {
            // Keep the old fingerprint so a later refresh retries the failed file.
            if let cached = cache.files[path] {
                refreshedFiles[path] = cached
                preservedLogPaths.insert(path)
            }
        }
```

把 `scan()` 返回结果中的：

```swift
            failedLogCount: failedLogPaths.count
```

替换为：

```swift
            preservedLogCount: preservedLogPaths.count,
            failedLogCount: enumeration.failedSourceCount + failedLogPaths.count
```

在 `scan()` 中 `cache.files = refreshedFiles` 之前追加：

```swift
        // Enumeration failures hide files, so missing cache entries are not proof of deletion.
        // Keep the last known counts for affected directories until a later scan succeeds.
        let preservedFiles = enumeration.cachedFilesToPreserve(from: cache)
        for (path, cached) in preservedFiles where refreshedFiles[path] == nil {
            refreshedFiles[path] = cached
            preservedLogPaths.insert(path)
        }
```

删除整个私有方法 `historyLogURLs()`（包括其文档注释）。Codex 现在与 CodeBuddy/Qoder 共用同一套目录枚举失败统计和缓存保留逻辑。

把 `loadCache()` 和 `saveCache(_:)` 两个方法替换为：

```swift
    /// Read a versioned local cache. Invalid or old files safely fall back to a clean first scan.
    private func loadCache() -> SkillUsageLogCache {
        SkillUsageLogCache.load(from: cacheURL)
    }

    /// Persist atomically so an interrupted app launch cannot leave a half-written cache.
    private func saveCache(_ cache: SkillUsageLogCache) {
        cache.save(to: cacheURL, fileManager: fileManager)
    }
```

把 `fingerprint(for:)` 替换为：

```swift
    /// Size plus modification time is a cheap and sufficient cache fingerprint for append-only logs.
    private func fingerprint(for url: URL) -> SkillUsageLogFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        return SkillUsageLogFingerprint(
            fileSize: UInt64(fileSize),
            modificationDate: modificationDate
        )
    }
```

把 `consume` 的签名改为：

```swift
    private func consume(line: String, records: inout [String: MutableSkillUsageRecord]) {
```

把其中的时间戳解析行：

```swift
        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
```

改为：

```swift
        let timestamp = (object["timestamp"] as? String)
            .flatMap(SkillUsageTimestampParser.parseISO8601)
```

删除 Codex 文件末尾私有方法 `parseTimestamp(_:)`，以及以下四个私有类型：

```swift
    private struct MutableUsageRecord { ... }
    private struct UsageCache: Codable { ... }
    private struct CachedLogResult: Codable { ... }
    private struct LogFingerprint: Codable, Equatable { ... }
```

保留 `ChangedLogScanResult`，它现在使用共享类型。

- [ ] **Step 12: 验证 Codex 与扫描器行为**

Run:

```bash
swift test --filter CodexSkillUsageServiceTests
swift test --filter SkillUsageJSONLScannerTests
```

Expected:

```text
Executed 6 tests, with 0 failures
Executed 5 tests, with 0 failures
```

（如果 Xcode 版本输出的数量不同，以 0 failures 为准。）

---

## Task 2: CodeBuddy Provider

**Files:**

- Create: `Sources/SkillDeck/Services/SkillUsage/CodeBuddySkillUsageService.swift`
- Create: `Tests/SkillDeckTests/CodeBuddySkillUsageServiceTests.swift`

说明：只统计 `function_call_result` 且 `status == "completed"` 的事件，skill 名从结果文本 `Base directory for this skill: <path>` 的末级目录提取。这样自然排除失败的 `Skill` 调用，也不会把 `function_call` 和 `function_call_result` 重复计数。

- [ ] **Step 1: 写失败测试**

Create `Tests/SkillDeckTests/CodeBuddySkillUsageServiceTests.swift`:

```swift
import Foundation
import XCTest

@testable import SkillDeck

final class CodeBuddySkillUsageServiceTests: XCTestCase {
    func testScanCountsCompletedSkillResultsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            try makeResult(timestamp: 1_790_000_000_000, status: "completed", skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_100_000, status: "completed", skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_200_000, status: "error", skillID: "gzh-design"),
            try makeCall(timestamp: 1_790_000_300_000, skillID: "gzh-design"),
            try makeResult(timestamp: 1_790_000_400_000, status: "completed", skillID: nil),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await CodeBuddySkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 2)
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_100)
        )
        XCTAssertNil(result.records[""])
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckCodeBuddyMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await CodeBuddySkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func makeResult(timestamp: Int, status: String, skillID: String?) throws -> String {
        let outputText: String
        if let skillID {
            outputText = "Base directory for this skill: /Users/test/.codebuddy/skills/\(skillID)\n# \(skillID)"
        } else {
            outputText = "Operation completed"
        }

        return try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call_result",
            "name": "Skill",
            "callId": UUID().uuidString,
            "status": status,
            "output": [
                "type": "text",
                "text": outputText,
            ],
        ])
    }

    private func makeCall(timestamp: Int, skillID: String) throws -> String {
        try jsonLine([
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "type": "function_call",
            "name": "Skill",
            "callId": UUID().uuidString,
            "arguments": "{\"skill\":\"\(skillID)\"}",
        ])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeJSONL(_ lines: [String], to url: URL) throws {
        let contents = lines.joined(separator: "\n") + "\n"
        try XCTUnwrap(contents.data(using: .utf8)).write(to: url, options: .atomic)
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckCodeBuddyTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
swift test --filter CodeBuddySkillUsageServiceTests
```

Expected: 编译失败，提示 `cannot find 'CodeBuddySkillUsageService' in scope`。

- [ ] **Step 3: 实现 Provider**

Create `Sources/SkillDeck/Services/SkillUsage/CodeBuddySkillUsageService.swift`:

```swift
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
            parse: Self.parse(line:)
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
            parse: Self.parse(line:)
        )
    }

    func scan() -> SkillUsageScanResult {
        scanner.scan()
    }

    private static func parse(line: String) -> [SkillUsageEvent] {
        guard line.contains("function_call_result"), line.contains("Skill") else {
            return []
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "function_call_result",
              object["name"] as? String == "Skill",
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

    private static func skillID(from output: String) -> String? {
        let marker = "Base directory for this skill: "
        guard let markerRange = output.range(of: marker) else { return nil }

        let path = output[markerRange.upperBound...]
            .prefix { !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        let skillID = URL(fileURLWithPath: path).lastPathComponent
        return skillID.isEmpty ? nil : skillID
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:

```bash
swift test --filter CodeBuddySkillUsageServiceTests
```

Expected:

```text
Executed 2 tests, with 0 failures
```


---

## Task 3: Qoder Provider

**Files:**

- Create: `Sources/SkillDeck/Services/SkillUsage/QoderSkillUsageService.swift`
- Create: `Tests/SkillDeckTests/QoderSkillUsageServiceTests.swift`

说明：只认 system 激活消息。一次 `/skilldeck` 会同时产生 user 命令消息、system 激活消息和 skill 内容消息；只计 system 消息可以避免重复计数，也不会把 `/quit`、`/model` 等内置命令算进去。

- [ ] **Step 1: 写失败测试**

Create `Tests/SkillDeckTests/QoderSkillUsageServiceTests.swift`:

```swift
import Foundation
import XCTest

@testable import SkillDeck

final class QoderSkillUsageServiceTests: XCTestCase {
    func testScanCountsSystemActivationMessagesOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("SkillDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            try makeSystemEvent(timestamp: "2026-10-21T05:06:18.458Z", content: "Skill **skilldeck** activated."),
            try makeSystemEvent(timestamp: "2026-10-21T05:07:18.458Z", content: "Skill **gzh-design** activated."),
            try makeSystemEvent(timestamp: "2026-10-21T05:08:18.458Z", content: "Skill **skilldeck** activated."),
            try makeUserEvent(content: "<command-name>/skilldeck</command-name>"),
            try makeUserEvent(content: "Base directory for this skill: /Users/test/.agents/skills/skilldeck"),
            try makeSystemEvent(timestamp: "2026-10-21T05:09:18.458Z", content: "Something else"),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await QoderSkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["quit"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T05:08:18.458Z")
        )
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckQoderMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await QoderSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func makeSystemEvent(timestamp: String, content: String) throws -> String {
        try jsonLine([
            "type": "system",
            "subtype": "informational",
            "timestamp": timestamp,
            "content": content,
        ])
    }

    private func makeUserEvent(content: String) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": "2026-10-21T05:06:18.328Z",
            "message": [
                "role": "user",
                "content": content,
            ],
        ])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeJSONL(_ lines: [String], to url: URL) throws {
        let contents = lines.joined(separator: "\n") + "\n"
        try XCTUnwrap(contents.data(using: .utf8)).write(to: url, options: .atomic)
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckQoderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
swift test --filter QoderSkillUsageServiceTests
```

Expected: 编译失败，提示 `cannot find 'QoderSkillUsageService' in scope`。

- [ ] **Step 3: 实现 Provider**

Create `Sources/SkillDeck/Services/SkillUsage/QoderSkillUsageService.swift`:

```swift
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
            parse: Self.parse(line:)
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
            parse: Self.parse(line:)
        )
    }

    func scan() -> SkillUsageScanResult {
        scanner.scan()
    }

    private static func parse(line: String) -> [SkillUsageEvent] {
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
```

- [ ] **Step 4: 运行测试确认通过**

Run:

```bash
swift test --filter QoderSkillUsageServiceTests
```

Expected:

```text
Executed 2 tests, with 0 failures
```


---

## Task 4: OpenCode 2.x Provider

**Files:**

- Create: `Sources/SkillDeck/Services/SkillUsage/OpenCodeSkillUsageService.swift`
- Create: `Tests/SkillDeckTests/OpenCodeSkillUsageServiceTests.swift`

说明：只读 `opencode.db` 的 `part` 表，不读写 1.x 的 `storage/part/*.json`。`part.data` 约 61 MB，用户手动刷新或每次启动首次打开详情页时查询一次即可，不增加磁盘缓存。

- [ ] **Step 1: 写失败测试**

Create `Tests/SkillDeckTests/OpenCodeSkillUsageServiceTests.swift`:

```swift
import Darwin
import Foundation
import SQLite3
import XCTest

@testable import SkillDeck

final class OpenCodeSkillUsageServiceTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func testScanCountsCompletedSkillPartsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try makeDatabase(at: databaseURL, rows: [
            Row(id: "p1", tool: "skill", skill: "web-access", status: "completed", timestamp: 1_790_000_000_000),
            Row(id: "p2", tool: "skill", skill: "web-access", status: "error", timestamp: 1_790_000_100_000),
            Row(id: "p3", tool: "skill", skill: "gzh-design", status: "completed", timestamp: 1_790_000_200_000),
            Row(id: "p4", tool: "bash", skill: "ignored", status: "completed", timestamp: 1_790_000_300_000),
        ])

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["web-access"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["ignored"])
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            Date(timeIntervalSince1970: 1_790_000_200)
        )
    }

    func testScanReturnsNoCoverageWhenDatabaseIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckOpenCodeMissing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("opencode.db")

        let result = await OpenCodeSkillUsageService(databaseURL: missing).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    /// An existing but corrupt database is a read failure, not "no history".
    func testScanReportsUnreadableDatabaseAsFailure() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try "not a sqlite database".write(to: databaseURL, atomically: true, encoding: .utf8)

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    /// An unreadable parent must not be mistaken for a missing database.
    func testScanReportsInaccessibleDatabaseAsFailure() async throws {
        try XCTSkipIf(getuid() == 0, "Permission checks do not apply when tests run as root")

        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let agentDirectory = fixture.root.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        let databaseURL = agentDirectory.appendingPathComponent("opencode.db")
        try "unused".write(to: databaseURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: agentDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: agentDirectory.path
            )
        }

        let result = await OpenCodeSkillUsageService(databaseURL: databaseURL).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    private struct Row {
        let id: String
        let tool: String
        let skill: String
        let status: String
        let timestamp: Int64
    }

    private func makeDatabase(at url: URL, rows: [Row]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let createSQL = """
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 2)
        }

        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES (?, '', '', ?, ?, ?);
        """
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            let payload: [String: Any] = [
                "type": "tool",
                "tool": row.tool,
                "state": [
                    "status": row.status,
                    "input": ["name": row.skill],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (row.id as NSString).utf8String, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, row.timestamp)
            sqlite3_bind_int64(statement, 3, row.timestamp)
            sqlite3_bind_text(statement, 4, (json as NSString).utf8String, -1, Self.transient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeSkillUsageServiceTests", code: 4)
            }
        }
    }

    private struct TemporaryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
swift test --filter OpenCodeSkillUsageServiceTests
```

Expected: 编译失败，提示 `cannot find 'OpenCodeSkillUsageService' in scope`。

- [ ] **Step 3: 实现 Provider**

Create `Sources/SkillDeck/Services/SkillUsage/OpenCodeSkillUsageService.swift`:

```swift
import Foundation
import SQLite3

/// Recovers skill invocations from OpenCode 2.x's local SQLite database.
///
/// OpenCode 2.x stores tool calls in `part.data` as JSON. Legacy 1.x JSON files under
/// `storage/part/` are intentionally ignored because current OpenCode versions no longer write
/// there. The `part` table is small enough (tens of MB) to query in full on demand.
actor OpenCodeSkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .openCode }

    private let databaseURL: URL

    /// Production initializer based on the current macOS user's home directory.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }

    /// Test initializer that points at a temporary SQLite fixture.
    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func scan() -> SkillUsageScanResult {
        switch SkillUsagePathProbe.status(at: databaseURL) {
        case .missing:
            return SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 0
            )
        case .directory, .inaccessible:
            // The path exists but cannot be a readable database, or its parent cannot be
            // inspected. Report a failure instead of claiming there is no history.
            return SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 1
            )
        case .notDirectory:
            break
        }

        guard let rows = readSkillRows() else {
            // The database exists but could not be read. Report zero readable coverage so the
            // manager maps this to `.failed` instead of `.available` with "no usage detected".
            return SkillUsageScanResult(
                records: [:], scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 1
            )
        }

        var records: [String: MutableSkillUsageRecord] = [:]
        for row in rows where row.status == "completed" {
            var record = records[row.skillID] ?? MutableSkillUsageRecord()
            record.detectedInvocationCount += 1
            if let timestamp = row.timestamp,
               record.lastDetectedAt == nil || timestamp > record.lastDetectedAt! {
                record.lastDetectedAt = timestamp
            }
            records[row.skillID] = record
        }

        return SkillUsageScanResult(
            records: records.mapValues {
                SkillUsageRecord(
                    detectedInvocationCount: $0.detectedInvocationCount,
                    lastDetectedAt: $0.lastDetectedAt
                )
            },
            scannedLogCount: 1,
            preservedLogCount: 0,
            failedLogCount: 0
        )
    }

    private struct SkillRow {
        let skillID: String
        let status: String
        let timestamp: Date?
    }

    private func readSkillRows() -> [SkillRow]? {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase = database else {
            // SQLite may allocate a handle even when opening fails; close it to avoid leaking
            // one connection per refresh attempt against a corrupt or unreadable database.
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(openedDatabase) }
        sqlite3_busy_timeout(openedDatabase, 2_000)

        let sql = """
        SELECT json_extract(data, '$.state.input.name'),
               json_extract(data, '$.state.status'),
               time_created
        FROM part
        WHERE json_extract(data, '$.tool') = 'skill'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(openedDatabase, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SkillRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return rows
            }
            guard step == SQLITE_ROW else {
                return nil
            }
            guard let nameText = sqlite3_column_text(statement, 0),
                  let statusText = sqlite3_column_text(statement, 1) else {
                continue
            }

            let skillID = String(cString: nameText)
            guard !skillID.isEmpty else { continue }

            let createdAt = sqlite3_column_int64(statement, 2)
            rows.append(SkillRow(
                skillID: skillID,
                status: String(cString: statusText),
                timestamp: createdAt > 0
                    ? Date(timeIntervalSince1970: Double(createdAt) / 1000)
                    : nil
            ))
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:

```bash
swift test --filter OpenCodeSkillUsageServiceTests
```

Expected:

```text
Executed 4 tests, with 0 failures
```


---

## Task 5: SkillManager 多 Provider 聚合

**Files:**

- Modify: `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`（追加默认工厂）
- Modify: `Sources/SkillDeck/Services/SkillManager.swift:105-112,147-148,167-202`
- Create: `Tests/SkillDeckTests/SkillManagerUsageTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/SkillDeckTests/SkillManagerUsageTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
swift test --filter SkillManagerUsageTests
```

Expected: 编译失败，提示 `extra argument 'skillUsageProviders' in call` 或找不到 `skillUsage(for:agent:)`。

- [ ] **Step 3: 新增默认 Provider 工厂**

在 `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift` 的协议定义之后追加：

```swift
/// Production provider set. Tests inject their own providers through `SkillManager.init`.
///
/// This factory lives here (instead of in Task 1) because it references all four concrete
/// services, which do not exist until Tasks 2-4 are complete.
enum SkillUsageProviderFactory {
    static func makeDefaultProviders() -> [any SkillUsageProvider] {
        [
            CodexSkillUsageService(),
            CodeBuddySkillUsageService(),
            QoderSkillUsageService(),
            OpenCodeSkillUsageService(),
        ]
    }
}
```

Run:

```bash
swift build
```

Expected: 构建成功。如果失败，检查 Tasks 2-4 的 service 类型名是否与上面完全一致。

- [ ] **Step 4: 替换 SkillManager 的 Codex 专用状态**

把 `Sources/SkillDeck/Services/SkillManager.swift` 第 105-112 行替换为：

```swift
    /// Best-effort invocation evidence per Agent, indexed by `Skill.id`.
    ///
    /// Keeping all providers' indexes in the shared manager lets skill detail pages reuse one
    /// history scan instead of performing duplicate filesystem work.
    var skillUsageRecords: [AgentType: [String: SkillUsageRecord]] = [:]

    /// Current coverage state per Agent. Missing entries mean `.notScanned`.
    var skillUsageScanStates: [AgentType: SkillUsageScanState] = [:]
```

把第 147-148 行替换为：

```swift
    /// Agent-specific adapters for reconstructing historical skill invocations.
    private let skillUsageProviders: [AgentType: any SkillUsageProvider]
```

把第 167-170 行的初始化方法替换为：

```swift
    init(
        skillUsageProviders: [any SkillUsageProvider] = SkillUsageProviderFactory.makeDefaultProviders()
    ) {
        self.skillUsageProviders = Dictionary(
            skillUsageProviders.map { ($0.agentType, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        setupFileWatcher()
    }
```

- [ ] **Step 5: 替换加载与查询方法**

把第 172-202 行从 `/// Load the Codex usage index once...` 开始到 `codexSkillUsage(for:)` 结束的整段替换为：

```swift
    /// Scan every supported Agent once on first use, or rescan all providers when forced.
    ///
    /// Providers run concurrently because each one has an independent history source. Results are
    /// collected before touching observable state so the main actor is not used inside the task
    /// group body.
    func loadSkillUsage(forceRefresh: Bool = false) async {
        let providers = skillUsageProviders.values.filter { provider in
            let state = skillUsageScanState(for: provider.agentType)
            if state == .scanning {
                return false
            }
            return forceRefresh || state == .notScanned
        }
        guard !providers.isEmpty else { return }

        for provider in providers {
            skillUsageScanStates[provider.agentType] = .scanning
        }

        let results = await withTaskGroup(
            of: (AgentType, SkillUsageScanResult).self
        ) { group in
            for provider in providers {
                let agentType = provider.agentType
                group.addTask {
                    (agentType, await provider.scan())
                }
            }

            var collected: [(AgentType, SkillUsageScanResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (agentType, result) in results {
            skillUsageRecords[agentType] = result.records
            if result.scannedLogCount > 0 {
                skillUsageScanStates[agentType] = .available(
                    scannedLogCount: result.scannedLogCount,
                    preservedLogCount: result.preservedLogCount,
                    failedLogCount: result.failedLogCount
                )
            } else if result.failedLogCount > 0 {
                // A source exists but none of it could be read. Keep this distinct from
                // `.unavailable` so the UI can warn instead of claiming there is no history.
                skillUsageScanStates[agentType] = .failed(failedLogCount: result.failedLogCount)
            } else {
                skillUsageScanStates[agentType] = .unavailable
            }
        }
    }

    /// Return usage evidence for one skill and Agent after the shared index has been loaded.
    func skillUsage(for skillID: String, agent: AgentType) -> SkillUsageRecord? {
        skillUsageRecords[agent]?[skillID]
    }

    func skillUsageScanState(for agent: AgentType) -> SkillUsageScanState {
        skillUsageScanStates[agent] ?? .notScanned
    }

    func isSkillUsageSupported(_ agent: AgentType) -> Bool {
        skillUsageProviders[agent] != nil
    }

    var isScanningSkillUsage: Bool {
        skillUsageProviders.keys.contains { skillUsageScanState(for: $0) == .scanning }
    }

    var hasUnscannedSkillUsage: Bool {
        skillUsageProviders.keys.contains { skillUsageScanState(for: $0) == .notScanned }
    }

    var skillUsageFailedLogCount: Int {
        skillUsageScanStates.values.reduce(0) { partial, state in
            switch state {
            case .available(_, _, let failedLogCount):
                return partial + failedLogCount
            case .failed(let failedLogCount):
                return partial + failedLogCount
            case .notScanned, .scanning, .unavailable:
                return partial
            }
        }
    }
```

- [ ] **Step 6: 运行测试确认通过**

Run:

```bash
swift test --filter SkillManagerUsageTests
```

Expected:

```text
Executed 4 tests, with 0 failures
```

---

## Task 6: UI 行内展示 + 本地化

**Files:**

- Modify: `Sources/SkillDeck/Views/Components/AgentToggleView.swift`
- Modify: `Sources/SkillDeck/Views/Detail/SkillDetailView.swift`
- Modify: `Sources/SkillDeck/Utilities/Localization/L10nKeys.swift`
- Modify: `Sources/SkillDeck/Resources/Localizations/en.lproj/Localizable.strings`
- Modify: `Sources/SkillDeck/Resources/Localizations/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: 更新 L10nKeys**

把 `Sources/SkillDeck/Utilities/Localization/L10nKeys.swift` 第 93-105 行替换为：

```swift
    static let usageScanAction = "usage.scan.action"
    static let usageScanning = "usage.scanning"
    static let usageRefreshHelp = "usage.refresh.help"
    static let usageIncompleteHelp = "usage.incomplete.help"
    static let usageCaveat = "usage.caveat"
    static let usageAgentUsesFormat = "usage.agent.usesFormat"
    static let usageAgentLastUsedFormat = "usage.agent.lastUsedFormat"
    static let usageAgentNeverDetected = "usage.agent.neverDetected"
    static let usageAgentScanning = "usage.agent.scanning"
    static let usageAgentUnreadable = "usage.agent.unreadable"
    static let usageAgentUnavailable = "usage.agent.unavailable"
```

把 `allKeys` 数组中原来的 usage 项（从 `usageSectionTitle` 到 `usageIncompleteHelp`）替换为：

```swift
        usageScanAction,
        usageScanning,
        usageRefreshHelp,
        usageIncompleteHelp,
        usageCaveat,
        usageAgentUsesFormat,
        usageAgentLastUsedFormat,
        usageAgentNeverDetected,
        usageAgentScanning,
        usageAgentUnreadable,
        usageAgentUnavailable,
```

- [ ] **Step 2: 更新英文文案**

把 `Sources/SkillDeck/Resources/Localizations/en.lproj/Localizable.strings` 第 95-107 行替换为：

```text
"usage.scan.action" = "Scan History";
"usage.scanning" = "Scanning local Agent history...";
"usage.refresh.help" = "Rescan skill usage history";
"usage.incomplete.help" = "Some Agent history files or directories could not be read; usage statistics may be incomplete";
"usage.caveat" = "Detected from each Agent's local history. Missing logs and project references are not included.";
"usage.agent.usesFormat" = "%d uses";
"usage.agent.lastUsedFormat" = "Last used %@";
"usage.agent.neverDetected" = "No local usage detected";
"usage.agent.scanning" = "Scanning usage...";
"usage.agent.unreadable" = "Local history could not be read";
"usage.agent.unavailable" = "No local history";
```

- [ ] **Step 3: 更新中文文案**

把 `Sources/SkillDeck/Resources/Localizations/zh-Hans.lproj/Localizable.strings` 第 95-107 行替换为：

```text
"usage.scan.action" = "扫描历史";
"usage.scanning" = "正在扫描本地 Agent 历史记录…";
"usage.refresh.help" = "重新扫描 skill 使用记录";
"usage.incomplete.help" = "部分 Agent 历史文件或目录无法读取，使用统计可能不完整";
"usage.caveat" = "统计来自各 Agent 的本地历史记录，缺失的日志和项目引用不会计入。";
"usage.agent.usesFormat" = "已使用 %d 次";
"usage.agent.lastUsedFormat" = "最近使用 %@";
"usage.agent.neverDetected" = "未检测到本地使用";
"usage.agent.scanning" = "正在扫描使用记录…";
"usage.agent.unreadable" = "本地历史无法读取";
"usage.agent.unavailable" = "无本地历史记录";
```

- [ ] **Step 4: 在 AgentToggleRow 中展示 usage**

修改 `Sources/SkillDeck/Views/Components/AgentToggleView.swift`。

在 `AgentToggleRow` 的环境依赖中追加：

```swift
    @Environment(\.locale) private var locale
    @Environment(\.localizationBundle) private var localizationBundle
```

把 `body` 中的 Agent 名称：

```swift
            Text(agentType.displayName)
```

替换为：

```swift
            VStack(alignment: .leading, spacing: 2) {
                Text(agentType.displayName)
                usageSummary
            }
```

在 `AgentToggleRow` 的 `body` 后面追加：

```swift
    /// Compact, read-only usage evidence under the Agent name.
    ///
    /// This intentionally renders nothing before a scan. Showing "0 uses" for an unscanned Agent
    /// would make "unknown" look like "never used".
    @ViewBuilder
    private var usageSummary: some View {
        if skillManager.isSkillUsageSupported(agentType) {
            switch skillManager.skillUsageScanState(for: agentType) {
            case .notScanned:
                EmptyView()

            case .scanning:
                LText(key: L10nKeys.usageAgentScanning)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)

            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    LText(key: L10nKeys.usageAgentUnreadable)
                }
                .appFont(.caption)
                .foregroundStyle(.orange)

            case .unavailable:
                LText(key: L10nKeys.usageAgentUnavailable)
                    .appFont(.caption)
                    .foregroundStyle(.tertiary)

            case .available(_, let preservedLogCount, _):
                if let record = skillManager.skillUsage(for: skillID, agent: agentType) {
                    HStack(spacing: 4) {
                        Text(String(
                            format: localized(L10nKeys.usageAgentUsesFormat),
                            record.detectedInvocationCount
                        ))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .help(lastUsedHelp(record))

                        // Keep showing the last known count, but mark that it may come from
                        // the previous scan because this scan could not read the history.
                        if preservedLogCount > 0 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(localized(L10nKeys.usageIncompleteHelp))
                        }
                    }
                } else {
                    LText(key: L10nKeys.usageAgentNeverDetected)
                        .appFont(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func localized(_ key: String) -> String {
        L10n.string(key, bundle: localizationBundle, locale: locale)
    }

    private func lastUsedHelp(_ record: SkillUsageRecord) -> String {
        guard let lastDetectedAt = record.lastDetectedAt else {
            return localized(L10nKeys.usageCaveat)
        }

        let date = lastDetectedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
        return String(format: localized(L10nKeys.usageAgentLastUsedFormat), date)
    }
```

- [ ] **Step 5: 移除独立 Usage 区块并加扫描入口**

修改 `Sources/SkillDeck/Views/Detail/SkillDetailView.swift`。

1. 在 `body` 中删除：

```swift
                    // Best-effort historical usage recovered from local Codex session logs.
                    // Keep this above the long Agent list so first-time users can discover it.
                    usageSection(skill)

                    Divider()

```

保留后面的 `agentAssignmentSection()`。

2. 删除整个 `usageSection(_:)` 函数，从注释 `/// Usage evidence grouped by Agent. Codex is the first supported provider.` 开始，到 `markdownSection(_:)` 之前的最后一个右花括号结束。

3. 把 `agentAssignmentSection()` 替换为：

```swift
    /// Agent assignment list with per-Agent usage evidence shown inline.
    @ViewBuilder
    private func agentAssignmentSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Agent Assignment").appFont(.headline)

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(localized(L10nKeys.usageCaveat))

                if skillManager.skillUsageFailedLogCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(localized(L10nKeys.usageIncompleteHelp))
                }

                Spacer()

                usageScanControl
            }

            AgentToggleView(skillID: skillID, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var usageScanControl: some View {
        if skillManager.isScanningSkillUsage {
            ProgressView()
                .controlSize(.small)
        } else if skillManager.hasUnscannedSkillUsage {
            Button(localized(L10nKeys.usageScanAction)) {
                Task { await skillManager.loadSkillUsage() }
            }
            .controlSize(.small)
        } else {
            Button {
                Task { await skillManager.loadSkillUsage(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .help(localized(L10nKeys.usageRefreshHelp))
        }
    }
```

4. 在 `body` 的 `.task(id: skillID)` 中，把：

```swift
            .task(id: skillID) {
                await skillManager.maybeShowTranslationPackPromptIfNeeded(
                    translationEnabledOnThisScreen: showsChineseTranslation
                )
            }
```

改为：

```swift
            .task(id: skillID) {
                await skillManager.loadSkillUsage()
                await skillManager.maybeShowTranslationPackPromptIfNeeded(
                    translationEnabledOnThisScreen: showsChineseTranslation
                )
            }
```

- [ ] **Step 6: 运行本地化覆盖测试**

Run:

```bash
swift test --filter L10nKeysCoverageTests
```

Expected:

```text
Executed 1 test, with 0 failures
```

- [ ] **Step 7: 全量测试与构建**

Run:

```bash
swift test
swift build
```

Expected: 全部测试通过，`Build complete!`。

---

## Task 7: 人工验证与收尾

**Files:** 无

- [ ] **Step 1: 启动应用**

Run:

```bash
swift run SkillDeck
```

- [ ] **Step 2: 验证 Qoder 计数**

在 SkillDeck 中打开 `skilldeck` skill。本机 Qoder 历史中存在一次 `/skilldeck` 调用。

Expected:

- Qoder 行名称下方显示「已使用 1 次」（中文界面）或 `1 uses`（英文界面）。
- 悬停该行显示「最近使用 2026/10/21 ...」。
- Toggle 关闭时次数仍然显示。

- [ ] **Step 3: 验证 OpenCode 计数**

打开 `web-access` skill。

Expected:

- OpenCode 行显示本机检测到的 completed 调用次数（当前为 10；历史变化时以实际为准）。
- 失败的 1 次 `web-access` 不计入。

- [ ] **Step 4: 验证 CodeBuddy 计数**

打开 `gzh-design` skill。

Expected:

- CodeBuddy 行显示 2 次。
- Codex/Qoder 行只显示各自历史中的次数，不串数据。

- [ ] **Step 5: 验证状态语义**

- 首次打开详情页：标题旁短暂显示进度，随后显示刷新图标。
- 点击刷新：重新扫描，计数不重复累加。
- 没有历史的 Agent：显示「无本地历史记录」，不显示 0。
- 未支持的 Agent（Claude Code、Gemini 等）：不显示任何 usage 文本。
- 原独立 Usage 区块已消失。
- 本地历史文件或目录不可读时，标题旁出现橙色警告图标。
- 全部历史源不可读且没有上次缓存的 Agent：行内显示「本地历史无法读取」，不得显示「未检测到本地使用」或「无本地历史记录」。
- 全部历史源不可读但存在上次缓存：行内保留旧次数并显示橙色警告，不得清空计数或显示成「未检测到」。

- [ ] **Step 6: 最终全量验证**

Run:

```bash
swift test
swift build
```

Expected: 0 failures，构建成功。

- [ ] **Step 7: 检查改动范围（不提交）**

Run:

```bash
git status --short
```

Expected: 只出现本次修改的源码、测试和本地化文件；`.qoder/` 与 `docs/plans/2026-10-21-multi-agent-skill-usage.md` 保持未跟踪。不要执行 `git add -A` 或 `git commit`，由评审后按仓库约定手动提交。

---

## 5. 风险与边界

1. **格式变化**：CodeBuddy、Qoder、OpenCode 的本地格式都是非公开实现细节。每个 provider 独立，格式变化只影响对应 Agent；文件读取失败时保留缓存并显示警告，目录枚举失败时同样保留缓存并显示警告。
2. **Qoder system 文案**：当前为英文 `Skill **<name>** activated.`。若未来本地化或改文案，需要更新 `activatedSkillID(from:)`；不要退回到匹配 `SKILL.md` 路径。
3. **CodeBuddy 结果文案**：当前成功结果包含 `Base directory for this skill: <path>`。若未来变化，可在 provider 内增加按 `callId` 关联 `function_call.arguments` 的 fallback。
4. **OpenCode 只读并发**：数据库可能处于 WAL 写入状态；使用 `SQLITE_OPEN_READONLY` + `busy_timeout(2000ms)`。路径探测遇到权限错误、路径是目录或数据库读取失败时返回 `scannedLogCount: 0, preservedLogCount: 0, failedLogCount: 1`，由 `SkillManager` 映射为 `.failed`；只有 ENOENT/ENOTDIR 确认路径缺失才返回 `.unavailable`。
5. **性能**：CodeBuddy/Qoder 使用 64 KB 分块逐行读取，内存上限约为一个 chunk 加最长单行，并使用文件指纹缓存，缓存命中时不再读取文件。Codex 保留 grep 预筛，但 `candidateLines` 仍会把 grep 输出的候选行一次性读入 `Data` 再转成完整 `String`，峰值内存取决于候选数据量；若实测成为问题，可让 Codex 也流式消费 grep 输出。扫描在 provider actor 上执行，不阻塞主线程；首次冷扫描耗时仍与日志总量成正比。变更过的文件会从头流式重读，若实测冷扫描延迟明显，后续可增加按字节偏移的增量解析。OpenCode 每次扫描约 61 MB 的 `part` 数据，仅在首次打开或手动刷新时执行。
6. **全部历史不可读**：路径探测遇到权限错误、目录枚举失败、路径不是目录、文件读取失败都会计入 `failedLogCount`。目录枚举失败时保留受影响目录下已有的缓存条目，并把它们计入 `preservedLogCount`：此时状态仍是 `.available`，行内显示旧计数并带警告。只有 `scannedLogCount == 0 && failedLogCount > 0`（没有任何可用缓存）才映射为 `.failed`。只有 ENOENT/ENOTDIR 确认路径缺失时才是 `.unavailable`。
7. **不是删除安全证明**：统计只代表「本地历史中检测到的成功调用」。0 次不代表该 Agent 或项目没有引用该 skill。

---

## 6. 自检清单

- [ ] 四个 provider 都实现 `SkillUsageProvider`，且 `agentType` 正确。
- [ ] `SkillManager` 不再包含任何 `codexSkillUsage*` 命名。
- [ ] `SkillDetailView` 不再有独立 Usage 区块。
- [ ] 未扫描不显示 0；扫描成功且无记录才显示「未检测到」。
- [ ] `scannedLogCount == 0 && failedLogCount > 0`（无可用缓存）时进入 `.failed`，UI 显示「本地历史无法读取」，不显示「未检测到」或「无本地历史」。
- [ ] 旧缓存与本次读取分开计数：`preservedLogCount > 0` 时状态仍为 `.available`，行内显示旧次数并带警告。
- [ ] 路径探测用 `fstatat` 区分 missing 与 inaccessible；权限错误计入 `failedLogCount` 并有测试。
- [ ] 目录枚举失败计入 `failedLogCount`，并保留受影响目录的缓存计数（有对应测试）。
- [ ] CodeBuddy/Qoder 的 JSONL 扫描使用 `SkillUsageLineReader` 逐行读取，不再调用 `String(contentsOf:)` 读取日志；Codex 的 grep 候选行内存上限已在风险说明中标注。
- [ ] CodeBuddy 只计 completed result；OpenCode 只计 completed part；Qoder 只计 system activation。
- [ ] `swift test`、`swift build` 通过。
- [ ] 新增 localization key 同时存在于 en 和 zh-Hans，且已加入 `L10nKeys.allKeys`。
- [ ] 计划执行过程中没有使用 `git add -A` 或自动提交。
