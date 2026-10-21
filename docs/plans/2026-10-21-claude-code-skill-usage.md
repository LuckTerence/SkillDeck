# Claude Code Skill Usage Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Claude Code 增加与 Codex / CodeBuddy / Qoder / OpenCode 对齐的本地 skill 调用次数统计，并直接复用现有 Skill 详情页 Agent Assignment 行内的 usage 展示。

**Architecture:** 新增 `ClaudeCodeSkillUsageService`（`SkillUsageProvider` 的 actor 适配器），复用 `SkillUsageJSONLScanner` 的流式逐行读取、文件指纹缓存、失败保留语义和 `SkillManager` 聚合。唯一采纳的信号是 Claude Code 在 skill 展开提示开头写入的 `Base directory for this skill: <path>`。注册到 `SkillUsageProviderFactory` 后，UI、本地化、`SkillManager` 和缓存类型均无需改动。

**Tech Stack:** Swift 5.9、SwiftUI（macOS 14+）、XCTest、Foundation、JSONSerialization。

> **提交约定:** 本计划不包含自动 `git add` / `git commit` 步骤。每个 Task 完成后保留工作区改动，由实施者在评审后按仓库约定提交。禁止使用 `git add -A`。

> **范围说明:** `docs/plans/2026-10-21-multi-agent-skill-usage.md` 中「Claude Code、Gemini CLI 等其他 Agent 的 usage 统计」属于明确不做项。本计划只增量支持 Claude Code，不修改该历史计划文档。

---

## 1. 已确认的数据源

| 来源 | 格式 | 可用性 | 结论 |
|---|---|---|---|
| `~/.claude/projects/**/*.jsonl` | 会话转录 JSONL | 主数据源 | 同时覆盖斜杠命令和模型主动调用 |
| `~/.claude/history.jsonl` | 用户输入历史 JSONL | 可选补充 | 只含用户键入的斜杠命令，v1 不接入 |
| `~/.claude/stats-cache.json` | 聚合统计 | 不可用 | 只有按日总量，无 skill 维度 |
| `tengu_skill_tool_invocation` 遥测 | 远程事件 | 不可用 | 不落本地文件 |

### 1.1 本机验证结果（Claude Code 2.1.304）

- 会话转录位于 `~/.claude/projects/<project-slug>/<session-id>.jsonl`，子代理转录也会递归出现在该目录下。
- `Skill` 工具调用的成功结果文本为：
  - `Launching skill: <name>`
  - `Loaded skill instructions (read-only): <name>. ...`
  - `Skill "<name>" completed (forked execution). ...`
  - `Skill "<name>" launched (forked execution, running in the background). ...`
- 斜杠命令在 user 消息中表现为 `<command-name>/<name></command-name><command-message>...</command-message>`。
- 无论斜杠调用还是 `Skill` 工具调用，展开后的 skill 提示都会在开头写入：

  ```text
  Base directory for this skill: <absolute-skill-root-path>
  ```

  该文本来自 Claude Code 的 `getPromptForCommand`（二进制中已确认），随后作为 user 消息落盘。
- Claude Code 没有 Qoder 的 `Skill **<name>** activated.` system 消息（二进制中匹配数为 0），因此不能直接复用 `QoderSkillUsageService` 的解析规则。
- 本机 `/skilldeck` 的 Qoder 转录（Claude Code 兼容格式）验证了同一条消息链：命令记录 → 激活记录 → `Base directory for this skill: ...` 的 user 消息。Claude Code 只缺少中间的激活记录。

### 1.2 为什么只统计展开消息

| 候选信号 | 问题 |
|---|---|
| assistant `tool_use` 且 `name == "Skill"` | 斜杠调用没有该记录；失败调用也有该记录 |
| `Launching skill: <name>` tool_result | 斜杠调用没有该记录；与展开消息同时存在时会重复计数 |
| `<command-name>/<name></command-name>` | 无法区分 `/model`、`/clear` 等内建命令；模型调用没有该记录 |
| `Base directory for this skill: <path>` user 消息 | 两种调用路径各产生一次；内建命令和失败调用不产生；消息本身即代表 skill 已成功加载 |

因此 v1 采用「一条展开消息 = 一次 skill 加载」的语义。

### 1.3 明确不做

- 不统计 `~/.claude/history.jsonl`。它只记录用户键入的斜杠命令，无法覆盖模型主动调用，且混有内建命令和路径类误报。作为后续可选增强，见第 6 节。
- 不读取 `stats-cache.json`，不依赖遥测。
- 不扫描整个 `~/.claude`。只扫描 `~/.claude/projects`，避免把 `history.jsonl`、debug、telemetry 等文件纳入枚举。
- 不改变现有 UI、状态枚举、本地化 key 或其他 Agent 的解析规则。
- 不把 `tool_result` 内容中的标记计入。用户在 Claude Code 里 `grep`/`cat` SKILL.md 时，工具输出可能包含同样的文本。

---

## 2. 统计语义

- `skillID` 取展开路径的 `lastPathComponent`，与 SkillDeck 的 `Skill.id`（skill 目录名）保持一致。
- 一个 user 消息中最多产生一个事件，即使消息正文里重复出现标记，也不会多次计数。
- 时间戳取该 user 消息的 `timestamp`（ISO-8601，支持小数秒）。
- 只有 `type == "user"` 且 `message.content` 为字符串或 text block 的消息参与匹配；`tool_result` block 一律忽略。
- 模型主动调用、斜杠调用、forked/read-only 调用都以展开消息为准，各计一次。
- agent 预加载 skill 也会注入展开消息，因此会计入。这里「加载即使用」是刻意选择；如果后续需要排除，可依据消息元数据或来源字段再收紧。
- 统计范围是「本地仍可读取的转录」。Claude Code 默认按 `cleanupPeriodDays`（30 天）清理会话转录，因此计数可能少于真实历史；这与现有「detected from local history」语义一致。
- 历史目录缺失 → `.unavailable`；目录/文件不可读 → `.failed`；部分文件失败 → `.available` 并带警告；缓存保留行为全部沿用 `SkillUsageJSONLScanner`。

---

## 3. 验收标准

1. 打开任意 Skill 详情页，Claude Code 的 Agent Assignment 行会在名称下方显示检测到的调用次数；未扫描时不显示任何 usage 文本。
2. 同一 skill 经斜杠命令或模型 `Skill` 工具调用，各计一次，不因同时存在 `tool_use` / `tool_result` / 展开消息而重复计数。
3. `/model`、`/clear` 等内建命令，`Unknown skill` 等失败调用，以及工具输出中包含标记的文本，都不产生计数。
4. 次数为 0 时显示「未检测到本地使用」；历史源缺失时显示「无本地历史记录」；全部历史不可读时显示「本地历史无法读取」；这些状态与现有四种 Agent 完全一致。
5. Toggle（是否分配）与 usage 完全独立：关闭 Toggle 不影响已检测到的次数。
6. 首次扫描后生成 `~/.agents/.skilldeck-usage-cache-claude-code.json`；再次打开详情页复用缓存，手动刷新会重扫。
7. `swift test` 全绿，`swift build` 成功。
8. 现有 Codex / CodeBuddy / Qoder / OpenCode 的计数与测试不受影响。

---

## 4. 文件结构

**新增**

- `Sources/SkillDeck/Services/SkillUsage/ClaudeCodeSkillUsageService.swift`
- `Tests/SkillDeckTests/ClaudeCodeSkillUsageServiceTests.swift`

**修改**

- `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`：默认 provider 工厂增加一项。

**不改**

- `Sources/SkillDeck/Models/AgentType.swift`（`claudeCode` 已存在）
- `Sources/SkillDeck/Services/SkillManager.swift`
- `Sources/SkillDeck/Views/Components/AgentToggleView.swift`
- `Sources/SkillDeck/Views/Detail/SkillDetailView.swift`
- `Sources/SkillDeck/Utilities/Localization/*`
- `Sources/SkillDeck/Services/SkillUsage/SkillUsageJSONLScanner.swift`
- `Sources/SkillDeck/Models/SkillUsage.swift`

说明：`SkillManagerUsageTests` 使用注入的 fake providers，`isSkillUsageSupported(.claudeCode)` 仍为 `false`，无需修改现有断言。

---

## Task 0: 分支与基线

**Files:** 无

- [ ] **Step 1: 创建功能分支**

Run:

```bash
git switch main
git pull --ff-only
git switch -c feature/claude-code-skill-usage
git status --short
```

Expected: 进入新分支；除实施前已存在的改动外没有意外文件。

- [ ] **Step 2: 运行基线测试与构建**

Run:

```bash
swift test
swift build
```

Expected: 全部测试通过，`Build complete!`。

---

## Task 1: 真实样本验证（实现前置门）

**Files:** 无

**不要跳过本任务。** 本计划的核心假设是「模型通过 `Skill` 工具调用时也会写入 `Base directory for this skill:` 展开消息」。斜杠调用无法证明这一点，必须分别生成两条真实转录样本后再进入实现。

前提：用户同意消耗 API 额度。如果无法获得真实样本，默认按第 5 节风险 2 的 fallback 实现，不要基于未验证假设直接写主方案。

- [ ] **Step 1: 生成斜杠命令样本**

```bash
slash_json=$(mktemp)
claude -p --output-format json "/find-skills" > "$slash_json"
slash_session=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$slash_json")
slash_transcript=$(find ~/.claude/projects -name "$slash_session.jsonl" -print -quit)
printf 'slash transcript: %s\n' "$slash_transcript"
```

Expected: 输出非空的 transcript 路径。

- [ ] **Step 2: 生成模型 Skill 工具样本**

用自然语言明确要求通过 `Skill` 工具调用，不要输入 `/find-skills`：

```bash
tool_json=$(mktemp)
claude -p --output-format json --allowedTools Skill \
  "Invoke the find-skills skill through the Skill tool (not a slash command), then follow its instructions to list my available skills." \
  > "$tool_json"
tool_session=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$tool_json")
tool_transcript=$(find ~/.claude/projects -name "$tool_session.jsonl" -print -quit)
printf 'tool transcript: %s\n' "$tool_transcript"
```

如果模型没有触发 `Skill` 工具（例如直接回答），换更明确的提示或另一个容易触发的 skill 重试；这不视为产品失败，只说明本次样本无效。

如果当前 Claude Code 版本的 JSON 输出没有 `session_id` 字段，则在**每次调用后立刻**取最新转录（不要等两次调用都结束再取，否则两条命令都会指向同一个文件）：

```bash
# 在 Step 1 的 claude 命令之后执行
slash_transcript=$(find ~/.claude/projects -name '*.jsonl' -print0 | xargs -0 ls -t | head -1)

# 在 Step 2 的 claude 命令之后执行
tool_transcript=$(find ~/.claude/projects -name '*.jsonl' -print0 | xargs -0 ls -t | head -1)
```

两条转录必须是不同文件；如果相同，说明 `session_id` 查找失败且时序不可靠，重新分开执行两次调用并记录。

- [ ] **Step 3: 检查两条转录**

```bash
python3 - "$slash_transcript" "$tool_transcript" <<'EOF'
import json
import sys

MARKER = "Base directory for this skill:"


def expanded_skill_id(text):
    """Return the skill directory name only when the message begins with an expansion."""
    stripped = text.lstrip()
    if not stripped.startswith(MARKER):
        return None
    path_line = stripped[len(MARKER):].split("\n", 1)[0]
    path = path_line.split("  ", 1)[0].strip().rstrip("/")
    if not path:
        return None
    return path.rsplit("/", 1)[-1]


def inspect(path):
    tool_use = False
    expansions = set()
    for line in open(path, encoding="utf-8"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = record.get("message") or {}
        content = message.get("content")
        if isinstance(content, list):
            tool_use = tool_use or any(
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name") == "Skill"
                for block in content
            )
        if isinstance(content, str):
            texts = [content]
        elif isinstance(content, list):
            texts = [
                block.get("text", "")
                for block in content
                if isinstance(block, dict) and block.get("type") == "text"
            ]
        else:
            texts = []
        expansions.update(
            name for name in map(expanded_skill_id, texts) if name is not None
        )
    return tool_use, expansions


slash_tool_use, slash_expansions = inspect(sys.argv[1])
tool_use, tool_expansions = inspect(sys.argv[2])
slash_expansion = "find-skills" in slash_expansions
tool_expansion = "find-skills" in tool_expansions
print(
    f"slash: tool_use={slash_tool_use} expansion={slash_expansion} "
    f"skills={sorted(slash_expansions)}"
)
print(
    f"tool:  tool_use={tool_use} expansion={tool_expansion} "
    f"skills={sorted(tool_expansions)}"
)
assert slash_expansion, "slash sample did not expand find-skills"
assert tool_use and tool_expansion, "model-invoked sample did not write both records"
EOF
```

Expected:

```text
slash: tool_use=False expansion=True skills=['find-skills']
tool:  tool_use=True expansion=True skills=['find-skills']
```

检查只接受消息开头（允许前导空白）的展开标记，并把 `Base directory for this skill:` 后的路径按换行/两个连续空格截断，取末级目录名与 `find-skills` 精确比较；正文里出现 `find-skills` 不算通过。`skills=[...]` 列出实际展开的目录名，便于样本失败时判断模型加载了别的 skill。

斜杠样本中如果模型在同一回合又调用了其他 skill，`tool_use` 可能为 `True`；关键是 `expansion=True`。工具样本必须同时满足 `tool_use=True` 和 `expansion=True`。

- [ ] **Step 4: 判定**

| 观察结果 | 结论 |
|---|---|
| 斜杠路径 `expansion=True`，工具路径 `tool_use=True` + `expansion=True` | 采用主方案，继续 Task 2 |
| 斜杠路径 `expansion=False` | 展开信号整体不可用，改用 fallback |
| 工具路径 `tool_use=True` + `expansion=False` | 模型调用不落盘展开消息，改用 fallback |
| 工具路径 `tool_use=False` | 样本无效，调整提示重试；不得据此修改方案 |

fallback 的具体解析规则见第 5 节风险 2。采用 fallback 时，先更新本计划 Task 2 / Task 3 的测试与实现，再继续执行。

---

## Task 2: 写失败测试

**Files:**

- Create: `Tests/SkillDeckTests/ClaudeCodeSkillUsageServiceTests.swift`

- [ ] **Step 1: 新增测试**

```swift
import Foundation
import XCTest

@testable import SkillDeck

final class ClaudeCodeSkillUsageServiceTests: XCTestCase {
    func testScanCountsSkillExpansionsExactlyOnce() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines = [
            // Slash-command record: not an expansion and must not be counted.
            try userString(
                timestamp: "2026-10-21T09:00:00.000Z",
                content: "<command-name>/gzh-design</command-name><command-message>gzh-design</command-message>"
            ),
            // The expanded prompt is the actual, successful skill load.
            try userString(
                timestamp: "2026-10-21T09:00:00.100Z",
                content: "Base directory for this skill: /Users/test/.claude/skills/gzh-design\n\n# GZH Design"
            ),
            // Model-invoked skill: tool_use alone is not evidence of success.
            try jsonLine([
                "type": "assistant",
                "timestamp": "2026-10-21T09:01:00.000Z",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Skill",
                        "input": ["skill": "pdf"],
                    ]],
                ],
            ]),
            // A failed Skill call produces no expansion.
            try userString(
                timestamp: "2026-10-21T09:01:00.100Z",
                content: "Unknown skill: ghost"
            ),
            // The success result text is intentionally ignored; the expansion below is counted.
            try userBlocks(
                timestamp: "2026-10-21T09:01:00.200Z",
                blocks: [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": "Launching skill: pdf",
                    "is_error": false,
                ]]
            ),
            // Body on the same line: the path must stop at the two-space separator.
            try userString(
                timestamp: "2026-10-21T09:01:00.300Z",
                content: "Base directory for this skill: /Users/test/.claude/skills/pdf  # PDF"
            ),
            // Newer transcripts may store the expansion as text blocks.
            try userBlocks(
                timestamp: "2026-10-21T09:02:00.000Z",
                blocks: [[
                    "type": "text",
                    "text": "Base directory for this skill: /Users/test/.claude/skills/session-export\n\n# Session Export",
                ]]
            ),
            // Tool output containing the marker must not be counted.
            try userBlocks(
                timestamp: "2026-10-21T09:03:00.000Z",
                blocks: [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_2",
                    "content": "Base directory for this skill: /Users/test/.claude/skills/not-a-real-use",
                    "is_error": false,
                ]]
            ),
            // Built-in command has no skill expansion.
            try userString(
                timestamp: "2026-10-21T09:04:00.000Z",
                content: "<command-name>/model</command-name><command-message>model</command-message>"
            ),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: project.appendingPathComponent("session.jsonl"))

        let result = await ClaudeCodeSkillUsageService(
            historyDirectories: [projects],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["pdf"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["session-export"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["ghost"])
        XCTAssertNil(result.records["model"])
        XCTAssertNil(result.records["not-a-real-use"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["gzh-design"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:00:00.100Z")
        )
        // Must come from the expansion, not from the ignored "Launching skill" result.
        XCTAssertEqual(
            result.records["pdf"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:01:00.300Z")
        )
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckClaudeCodeMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await ClaudeCodeSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func userString(timestamp: String, content: String) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": content,
            ],
        ])
    }

    private func userBlocks(timestamp: String, blocks: [[String: Any]]) throws -> String {
        try jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": blocks,
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
                .appendingPathComponent("SkillDeckClaudeCodeTests-\(UUID().uuidString)", isDirectory: true)
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
swift test --filter ClaudeCodeSkillUsageServiceTests
```

Expected: 编译失败，提示 `cannot find 'ClaudeCodeSkillUsageService' in scope`。

---

## Task 3: 实现 Provider

**Files:**

- Create: `Sources/SkillDeck/Services/SkillUsage/ClaudeCodeSkillUsageService.swift`

- [ ] **Step 1: 新增服务**

```swift
import Foundation

/// Recovers skill activations from Claude Code's project JSONL transcripts.
///
/// Claude Code writes no dedicated activation record. Both invocation paths expand the skill
/// prompt and prepend `Base directory for this skill: <path>`:
/// - a user slash command such as `/gzh-design`
/// - the model's `Skill` tool call
///
/// Counting that marker counts each activation exactly once and naturally excludes built-in
/// slash commands, failed `Skill` calls, and plain tool output that happens to contain the text.
actor ClaudeCodeSkillUsageService: SkillUsageProvider {
    nonisolated var agentType: AgentType { .claudeCode }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [claudeDirectory.appendingPathComponent("projects", isDirectory: true)],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-claude-code.json"),
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

    private static let skillMarker = "Base directory for this skill: "

    private static let parse: @Sendable (String) -> [SkillUsageEvent] = { line in
        guard line.contains(skillMarker) else { return [] }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = userMessageText(from: object),
              let skillID = skillID(from: text) else {
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

    /// Returns text only for real user prompts, never for `tool_result` blocks.
    ///
    /// A tool result can contain the marker when a user greps SKILL.md files; counting that
    /// would invent usage. Skill expansion content is stored as plain text or text blocks.
    private static func userMessageText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              let message = object["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }

        if let text = content as? String {
            return text
        }

        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func skillID(from text: String) -> String? {
        guard let markerRange = text.range(of: skillMarker) else { return nil }

        // Claude Code separates the skill root from the SKILL.md body with two spaces.
        // Limiting to the first line also matches Qoder-style expansions.
        let pathLine = String(text[markerRange.upperBound...].prefix { !$0.isNewline })
        let path = (pathLine.components(separatedBy: "  ").first ?? pathLine)
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        let skillID = URL(fileURLWithPath: path).lastPathComponent
        return skillID.isEmpty ? nil : skillID
    }
}
```

- [ ] **Step 2: 运行测试确认通过**

Run:

```bash
swift test --filter ClaudeCodeSkillUsageServiceTests
```

Expected:

```text
Executed 2 tests, with 0 failures
```

---

## Task 4: 注册默认 Provider

**Files:**

- Modify: `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`

- [ ] **Step 1: 加入默认工厂**

把 `SkillUsageProviderFactory.makeDefaultProviders()` 中的数组改为：

```swift
    static func makeDefaultProviders() -> [any SkillUsageProvider] {
        [
            CodexSkillUsageService(),
            ClaudeCodeSkillUsageService(),
            CodeBuddySkillUsageService(),
            QoderSkillUsageService(),
            OpenCodeSkillUsageService(),
        ]
    }
```

- [ ] **Step 2: 构建**

Run:

```bash
swift build
```

Expected: `Build complete!`。

- [ ] **Step 3: 确认 UI 自动生效**

`AgentToggleView.usageSummary` 通过 `skillManager.isSkillUsageSupported(agentType)` 判断，`SkillDetailView` 扫描入口通过 `hasUnscannedSkillUsage` / `isScanningSkillUsage` 判断。注册 provider 后 Claude Code 行会自动出现扫描状态和次数，无需新增本地化 key。

---

## Task 5: 全量测试与人工验证

**Files:** 无

- [ ] **Step 1: 运行全量测试**

Run:

```bash
swift test
```

Expected: 0 failures。

- [ ] **Step 2: 启动应用人工验证**

Run:

```bash
swift run SkillDeck
```

Expected:

- 打开 Task 1 中实际调用过的 skill，Claude Code 行名称下方显示对应的调用次数（中文「已使用 N 次」/英文 `N uses`）。
- 悬停显示最近使用时间。
- 关闭 Toggle 后次数仍显示。
- `/model`、失败调用和工具输出中的标记不会增加任何 skill 的计数。
- 未调用过任何 skill 时显示「未检测到本地使用」，不显示 0。
- 点击刷新不会重复累加。
- 斜杠调用与模型调用各计一次（Task 1 的两条样本都计入时）。

- [ ] **Step 3: 最终构建**

Run:

```bash
swift test
swift build
```

Expected: 0 failures，`Build complete!`。

---

## 5. 风险与边界

1. **内部格式变化**：Claude Code 转录格式不是公开契约。本机 2.1.304 的转录已验证斜杠路径会写入展开消息；模型 `Skill` 工具路径由 Task 1 前置门验证。若文案或字段变化，修改 `ClaudeCodeSkillUsageService.parse` 并递增 `parserVersion` 即可。缓存文件独立，不影响其他 provider。
2. **模型调用不落盘展开消息（Task 1 前置门）**：Task 1 必须分别验证斜杠路径和自然语言触发的 `Skill` 工具路径。如果工具路径只写 `Launching skill: <name>` 而没有展开消息，应改为：
   - 斜杠路径：匹配 `<command-name>/<name></command-name>`（内建命令交给 UI 按 skill ID 自然过滤）；
   - 工具路径：只匹配四类成功 tool_result 文案；
   - 不要同时保留展开消息匹配，避免重复计数。

   该 fallback 需要额外的跨行/状态测试，因此放在实测失败后再做。
3. **agent 预加载**：预加载 skill 也会注入展开消息，会计入一次。若产品只希望统计显式调用，需要根据消息元数据或来源进一步过滤；当前接受「加载即使用」。
4. **转录清理**：Claude Code 默认 `cleanupPeriodDays = 30`，计数只覆盖仍保留的会话。`~/.claude/history.jsonl` 可以补斜杠调用，但无法补模型调用；如需要更长历史，见第 6 节。
5. **路径解析**：以换行或两个连续空格截断路径。macOS 路径中出现两个连续空格极罕见；若出现会被截断，可能漏计。SkillDeck 的 `Skill.id` 本身也取目录名，插件命名空间命令会自然归一到目录名。
6. **重复转录**：resume、compaction 或 fork 可能让同一展开消息在多个文件中出现。当前语义是「每一条展开记录计一次」；若实测发现明显重复，需要按 `sessionId` + 消息 `uuid` 去重。
7. **误报**：用户在 prompt 中粘贴 `Base directory for this skill:` 会被计入；概率极低，且路径末级目录通常不会匹配任何已安装 skill。工具输出中的标记已被显式排除。
8. **性能**：复用 `SkillUsageLineReader` 的 64 KB 分块读取和文件指纹缓存。首次冷扫描耗时与转录总量成正比，之后未变更文件直接命中缓存；扫描在 provider actor 上执行，不阻塞主线程。
9. **隐私**：只读本地 `~/.claude/projects` 和写 `~/.agents/.skilldeck-usage-cache-claude-code.json`，不访问网络、不上传内容。

---

## 6. 后续可选增强

### 6.1 用 `history.jsonl` 补充斜杠命令历史

- 位置：`~/.claude/history.jsonl`（本机约 2 MB，长期保留）。
- 字段：`display`（如 `/gzh-design args`）、`timestamp`（Unix 毫秒）、`project`、`sessionId`。
- 设计要点：
  - 这是替代方案而非增量方案：`history.jsonl` 负责斜杠路径，转录改为只统计 `Launching skill:` 等工具结果，二者不能与现有展开消息匹配叠加，否则斜杠调用会重复计数。
  - `plugin:skill` 取冒号后的末段；忽略以 `/Users/...` 等路径开头的条目。
  - 内建命令可以依赖 UI 按 skill ID 过滤，也可以维护一份保留名单。
  - `SkillUsageJSONLScanner` 目前只接受目录枚举，需要增加「显式文件列表」能力，或在 provider 内用 `SkillUsageLineReader` 单独解析并合并结果与失败计数。
- 本机匹配结果（2026-10-21）：19 个已安装 skill、124 次斜杠调用，其中 `/generate-wiki` 80 次、`/web-access` 8 次、`/gzh-design` 5 次。

### 6.2 去重与预加载过滤

如果真实样本显示 resume/compaction 会重复写入同一消息，或预加载不应计入，可在 provider 内按消息 `uuid` / `isMeta` / 来源字段去重和过滤，并为这些语义单独增加测试。

---

## 7. 自检清单

- [ ] `ClaudeCodeSkillUsageService` 实现 `SkillUsageProvider`，`agentType` 为 `.claudeCode`。
- [ ] 只匹配 user 消息的字符串/text block 内容，`tool_result` block 不参与。
- [ ] 斜杠调用与模型 `Skill` 调用各计一次，不因 tool_use / tool_result 重复。
- [ ] 内建命令、失败调用、工具输出中的标记均不计入。
- [ ] 展开路径按换行或两个连续空格截断，skill ID 取 `lastPathComponent`。
- [ ] 复用 `SkillUsageJSONLScanner` 的缓存、失败和保留语义，未新造一套状态。
- [ ] 默认工厂注册 Claude Code，UI 无改动即可显示。
- [ ] 缓存文件名为 `.skilldeck-usage-cache-claude-code.json`。
- [ ] `swift test`、`swift build` 通过。
- [ ] 真实样本分别验证两条路径：斜杠调用产生展开标记；自然语言触发的 `Skill` 工具调用同时产生 `tool_use` 和展开标记（或记录 fallback 决策）。
- [ ] `git status --short` 只包含本次源码、测试和本计划文件；没有使用 `git add -A` 或自动提交。
