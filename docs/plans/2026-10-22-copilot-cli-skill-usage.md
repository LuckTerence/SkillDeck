# Copilot CLI Skill Usage Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Copilot CLI 增加与 Codex / Claude Code / CodeBuddy / Qoder / OpenCode 对齐的本地 skill 调用次数统计，并直接复用现有 Skill 详情页 Agent Assignment 行内的 usage 展示。

**Architecture:** 新增 `CopilotSkillUsageService`（`SkillUsageProvider` 的 actor 适配器），复用 `SkillUsageJSONLScanner` 的流式逐行读取、文件指纹缓存、失败保留语义和 `SkillManager` 聚合。Copilot CLI 会为 skill 调用写入结构化的 `skill.invoked` 事件（失败调用是否也写盘由 Task 1 验证），因此不需要类似 Claude Code / Qoder 的提示词标记或工具输出启发式。注册到 `SkillUsageProviderFactory` 后，UI、本地化、`SkillManager` 和缓存类型均无需改动。

**Tech Stack:** Swift 5.9、SwiftUI（macOS 14+）、XCTest、Foundation、JSONSerialization。

> **提交约定:** 实现相关的改动不由本计划自动提交，每个 Task 完成后保留工作区改动，由实施者在评审后按仓库约定提交。Task 0 中提交计划文档的命令由实施者手动执行；禁止使用 `git add -A`。

> **范围说明:** 只增量支持 Copilot CLI，不修改 Claude Code、Codex、CodeBuddy、Qoder、OpenCode 的解析规则，也不修改多 Agent usage 的聚合与展示逻辑。

---

## 1. 已确认的数据源

| 来源 | 格式 | 可用性 | 结论 |
|---|---|---|---|
| `~/.copilot/session-state/<session-id>/events.jsonl` | 会话事件 JSONL | 主数据源 | 含结构化 `skill.invoked` 事件 |
| `~/.copilot/logs/*.log` | 进程/调试日志 | 未验证 | v1 不接入 |
| `~/.copilot/session-store.db` | SQLite | 未验证 | v1 不接入 |
| `~/.copilot/command-history-state.json` | 命令历史 | 不可用 | 只有用户输入，无法覆盖模型主动调用 |

### 1.1 本机验证结果（Copilot CLI 1.0.101）

- 会话历史位于 `~/.copilot/session-state/<session-id>/events.jsonl`，每个 session 一个目录；目录下还可能存在 `workspace.yaml`、`session.db`、`vscode.metadata.json` 等文件。扫描器只枚举 `.jsonl`，不会误读其他格式。
- skill 加载会产生独立事件，结构如下（已省略体量较大的 `content` 字段）：

  ```json
  {
    "type": "skill.invoked",
    "data": {
      "name": "pdf",
      "path": "/Users/test/.claude/skills/pdf/SKILL.md",
      "description": "...",
      "allowedTools": ["Read", "Bash"],
      "trigger": "agent-invoked",
      "source": "personal-agents"
    },
    "id": "067f62a2-...",
    "timestamp": "2026-03-05T07:29:11.075Z",
    "parentId": "2bc2415c-..."
  }
  ```

- 本机共扫描到 69 条 `skill.invoked` 事件，分布在 41 个 session 文件中；69 个事件 `id` 全部唯一，未发现同一事件重复落盘。
- 事件 `timestamp` 为 ISO-8601 且带小数秒（如 `2026-03-05T07:29:11.075Z`），可直接复用 `SkillUsageTimestampParser.parseISO8601`。
- `data.name` 与 `data.path` 的父目录名在 69 条样本中 69/69 一致。
- `trigger` 字段存在两种形态：`agent-invoked`（14 条）和缺省（55 条）；`source` 字段对应为 `personal-agents` 或缺失。两者都代表真实调用，v1 不据此过滤。
- 事件覆盖用户级 skill（`~/.copilot/skills`、`~/.claude/skills`、`~/.agents/skills`）、插件 skill（`~/.copilot/installed-plugins/...`）和项目级 skill（`<repo>/.claude/skills/...`）。

### 1.2 为什么 `skill.invoked` 是理想信号

| 候选信号 | 结论 |
|---|---|
| `tool.execution_start` 中 `toolName` / `arguments` 提及 skill | 只是工具调用开始，失败调用也可能存在 |
| `assistant.message` 文本中的 skill 名称 | 无法区分说明、搜索结果和真实调用 |
| `skill.invoked` 事件 | Copilot 主动写入的结构化调用事件，每次检测到的 skill 调用一条记录，字段完整；失败调用是否写盘由 Task 1 观察记录 |

因此 v1 采用「一条 `skill.invoked` = 一次检测到的 skill 调用事件」的语义，解析规则比其他 Agent 更简单、误报更少。该指标始终不承诺「成功使用次数」；Task 1 只记录一次「未知 skill」调用的观察结果，不用于泛化所有失败路径。UI 现有文案是通用的 `N uses`，与 detected invocation 语义兼容。

### 1.3 明确不做

- 不解析 `~/.copilot/logs` 和 `~/.copilot/session-store.db`。当前 `events.jsonl` 已能提供完整信号；其他来源格式未验证，接入会增加维护成本。
- 不按 `trigger`、`source`、`pluginName` 过滤。缺省字段同样代表真实调用，过滤会导致漏计。
- 不限制只统计 SkillDeck 管理的目录。Copilot 调用的项目级/插件 skill 也会被记录，这与 Claude Code Provider 的「检测到加载事件即计数」语义一致；同名冲突风险见第 5 节。
- 不修改 `SkillUsageJSONLScanner`、`SkillUsageLogCache`、`SkillManager`、UI 和本地化。
- 不 bump `SkillUsageLogCache.currentParserVersion`。新 Provider 使用独立缓存文件，首次扫描时缓存为空，不会影响其他 Agent 的缓存。
- 不统计 GitHub Copilot IDE 插件（VS Code / JetBrains）的聊天记录。本计划只覆盖 Copilot CLI。

---

## 2. 统计语义

- `skillID` 按以下优先级取值。空字段只在对应的优先级层级内表示「不可用」，不会让另一个层级的有效值失效：
  1. `data.path` 是非空字符串，且 `lastPathComponent == "SKILL.md"`，且父目录名非空 → 取父目录名（与 `Skill.id` 一致）。
  2. 否则，`data.name` 是非空字符串 → 取 `name`。
  3. 两者都不可用 → 忽略该事件。
- 举例：`name` 为空但 `path` 合法 → 按路径计数；`path` 缺失、为空或末级不是 `SKILL.md`，但 `name` 非空 → 按 `name` 计数；`name` 与路径父目录不一致 → 以路径为准。
- 一个 `skill.invoked` 事件产生一个 `SkillUsageEvent`；同一行不会被重复计数。
- 时间戳取事件的 `timestamp`（ISO-8601，支持小数秒）。
- 只有 `type == "skill.invoked"` 且 `data` 为对象的行参与匹配；其他事件类型、缺失 `data`、非字符串字段，以及按上述规则无法得到 `skillID` 的行一律忽略。
- 指标名称统一为「检测到的调用次数 / detected invocation count」。无论 Task 1 结果如何，都不使用「成功加载」「成功使用」等更强的表述；Task 1 只记录「未知 skill」场景的观察结果。
- 统计范围是「本地仍可读取的 `~/.copilot/session-state` 历史」。Copilot 清理会话、用户关闭历史或旧版本不写该事件时，计数会少于真实值；这与现有「detected from local history」语义一致。
- 历史目录缺失 → `.unavailable`；目录/文件不可读 → `.failed`；部分文件失败 → `.available` 并带警告；缓存保留行为全部沿用 `SkillUsageJSONLScanner`。
- 缓存文件为 `~/.agents/.skilldeck-usage-cache-copilot-cli.json`，与现有 Provider 的命名风格一致。

---

## 3. 验收标准

- [ ] Task 1 的语义观察已执行，并记录正向对照与目标事件的观察结果；指标始终使用 detected invocation 语义，不因单次结果切换为成功语义。
- [ ] `swift build` 成功。
- [ ] 新增 `CopilotSkillUsageServiceTests` 全部通过（3 个测试：解析 2 个 + Provider 注册 1 个）。
- [ ] `swift test` 全量通过（基线 220 个测试 + 新增 3 个测试 = 223）。
- [ ] Skill 详情页的 Copilot CLI 行出现 `N uses` 或 `Never detected`，不再因为 Provider 缺失而不显示 usage。
- [ ] 其他 Agent 的扫描结果、缓存文件、UI 行为和本地化文本无变化。
- [ ] `git diff` 只包含新增 Service、Provider 注册和新增测试，不包含无关格式化。

---

## 4. 文件结构

```text
Sources/SkillDeck/Services/SkillUsage/
├── CopilotSkillUsageService.swift        # 新增
└── SkillUsageProvider.swift              # 修改：注册默认 Provider

Tests/SkillDeckTests/
└── CopilotSkillUsageServiceTests.swift   # 新增
```

不新增模型、UI、本地化 key 或 `SkillManager` API。`SkillManager.isSkillUsageSupported(_:)` 会自动把 Copilot CLI 纳入支持列表，`AgentToggleView.usageSummary` 会自动显示统计结果。

---

## Task 0: 分支与基线

- [ ] 先同步 `main`。此时计划文档仍是未跟踪文件，`git status` 显示它是预期状态：

```bash
git switch main
git pull --ff-only
git status --short
```

预期：`main` 与远端一致；工作区只有 `?? docs/plans/2026-10-22-copilot-cli-skill-usage.md`。

- [ ] 从更新后的 `main` 创建功能分支，并在功能分支上提交计划文档：

```bash
git switch -c feature/copilot-cli-skill-usage
git add docs/plans/2026-10-22-copilot-cli-skill-usage.md
git commit -m "docs: add Copilot CLI skill usage plan"
git status --short
```

如果团队要求计划文档走独立的 docs PR，则先在 docs 分支提交并合并，再重新同步 `main` 后创建功能分支；不要直接提交到 `main`。

- [ ] 记录基线测试数量：

```bash
set -o pipefail
swift test 2>&1 | tail -5
```

预期：基线为 220 个测试全部通过。

---

## Task 1: `skill.invoked` 语义观察与正向对照

**目的：** 做两项观察：(1) 该 session 的 `events.jsonl` 能否正常记录有效的 skill 调用（正向对照）；(2) 一次「未知 skill」调用是否产生 `skill.invoked`。该验证用于记录事实和评估信号质量，不改变指标定义：无论结果如何，指标都保持 detected invocation count，不泛化为「成功使用」。

- [ ] 选择一个本机已安装、无副作用的 skill 作为正向对照，并生成固定 session ID：

```bash
copilot --version
VALID_SKILL="swiftui-expert-skill"   # 换成本机确实存在且无副作用的 skill
if ! { [ -d "$HOME/.copilot/skills/$VALID_SKILL" ] \
    || [ -d "$HOME/.claude/skills/$VALID_SKILL" ] \
    || [ -d "$HOME/.agents/skills/$VALID_SKILL" ]; }; then
  echo "VALID_SKILL not found; choose another skill"
  exit 1
fi
SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "VALID_SKILL=$VALID_SKILL"
echo "SESSION_ID=$SESSION_ID"
copilot --session-id "$SESSION_ID"
```

检查失败时 `exit 1` 会阻止启动 Copilot，避免把无效的正向对照当成有效验证。建议将这段检查保存为脚本或通过 `zsh -c '...'` 执行；直接在交互式 shell 中粘贴时，`exit 1` 会关闭当前终端会话。

注意：通过脚本或 `zsh -c` 启动时，`VALID_SKILL` 和 `SESSION_ID` 只存在于该子 shell，不会回到父 shell。请记录脚本输出的两个值，并在执行后续检查的终端中先重新设置：

```bash
VALID_SKILL="<上面输出的 VALID_SKILL>"
SESSION_ID="<上面输出的 SESSION_ID>"
```

`--session-id` 会为新会话指定 UUID（见 `copilot --help`），因此可以提前确定事件文件路径，避免新会话写入另一个目录后检查错文件。

- [ ] 在同一会话中按顺序执行：
  1. 输入 `/swiftui-expert-skill`（或刚才选择的 `VALID_SKILL`），等待 Copilot 确认 skill 已加载。
  2. 再输入 `/definitely-not-a-real-skill`，等待 CLI 给出错误或提示。
  3. 退出会话。

只做无副作用的 skill 加载，不使用 `--allow-all-tools` 执行模型生成的命令。

- [ ] 退出会话后，在已设置 `VALID_SKILL` 和 `SESSION_ID` 的终端中定位该 session 的精确事件文件：

```bash
EVENTS="$HOME/.copilot/session-state/$SESSION_ID/events.jsonl"
echo "$EVENTS"
```

- [ ] 解析当前 `$EVENTS`。用 JSON 解析而不是 `grep`，避免依赖 JSON 的紧凑格式；该命令直接接收 `$EVENTS`，不会从 `SESSION_ID` 重建路径：

```bash
VALID_SKILL="$VALID_SKILL" python3 - "$EVENTS" <<'EOF'
import json
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(f"events file not found: {path}")

target = "definitely-not-a-real-skill"
valid = os.environ.get("VALID_SKILL", "")
count = 0
positive_found = False
target_found = False

def skill_id(skill_name, skill_path):
    """Mirror the service: a valid SKILL.md parent directory wins over name."""
    if skill_path and os.path.basename(skill_path) == "SKILL.md":
        parent = os.path.basename(os.path.dirname(skill_path))
        if parent:
            return parent
    return skill_name

for line in open(path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") != "skill.invoked":
        continue

    data = event.get("data")
    if not isinstance(data, dict):
        data = {}

    name = str(data.get("name") or "")
    skill_path = str(data.get("path") or "")
    identifier = skill_id(name, skill_path)
    count += 1
    print("skill.invoked:", identifier, "| name:", name, "| path:", skill_path)

    if valid and identifier == valid:
        positive_found = True
        print("POSITIVE CONTROL FOUND")

    if identifier == target:
        target_found = True
        print("TARGET EVENT FOUND")

print(f"total skill.invoked: {count}")
print("positive control:", "FOUND" if positive_found else "MISSING")
print("invalid target event:", "FOUND" if target_found else "NOT FOUND")
EOF
```

如果 `--session-id` 在当前版本不生效，或该路径不存在：退出会话后，用 `EVENTS=$(/bin/ls -t ~/.copilot/session-state/*/events.jsonl | head -1); echo "$EVENTS"` 定位最新文件。然后只重新执行上面的 Python 解析步骤，它直接使用当前的 `$EVENTS`；不要重新执行正常路径的 `EVENTS="$HOME/.copilot/session-state/$SESSION_ID/events.jsonl"`，否则会用 `SESSION_ID` 覆盖刚找到的备用路径。若没有找到事件文件，记录为「未验证」。

**观察结论（必须同时看正向对照和目标事件，且不得外推）：**

- 正向对照 `MISSING` → 该 session 没有记录有效 skill，观察不成立。记录为「未验证」；先排查 session ID/路径并重试一次。指标仍为 detected invocation。
- 正向对照 `FOUND` + 目标 `NOT FOUND` → 仅记录为「本次未知 skill 场景未产生 `skill.invoked`」。不得据此推断其他失败路径（例如 skill 存在但加载失败）也不写事件，也不得改用「成功使用/成功加载」表述。
- 正向对照 `FOUND` + 目标 `FOUND` → 至少有一条失败路径也会写事件，进一步支持 detected invocation 语义。文档、代码注释和 PR 描述继续保持 detected invocation count；不要按 `trigger` / `source` 过滤，因为这会漏计正常调用。
- 会话未创建、事件文件不存在或无法触发无效 skill → 记录为「未验证」。指标仍为 detected invocation。

- [ ] 将观察结论写入 PR 描述或实现提交说明，注明正向对照是否命中，并明确「不改变 detected invocation 语义」。

---

## Task 2: 实现 `CopilotSkillUsageService`

- [ ] 新建 `Sources/SkillDeck/Services/SkillUsage/CopilotSkillUsageService.swift`，内容如下：

```swift
import Foundation

/// Recovers skill invocations from GitHub Copilot CLI's session event history.
///
/// Copilot CLI appends JSONL events to
/// `~/.copilot/session-state/<session-id>/events.jsonl`. Unlike transcript-based agents,
/// it emits a dedicated `skill.invoked` event for each skill invocation, so no
/// prompt-marker or tool-output heuristics are needed. Whether failed calls also emit this
/// event is only recorded as an observation; the metric remains a detected invocation count.
/// The event's `data` object contains the skill `name` and the `path` to its `SKILL.md`.
actor CopilotSkillUsageService: SkillUsageProvider {
    /// Agent whose local history this adapter reads.
    nonisolated var agentType: AgentType { .copilotCLI }

    private let scanner: SkillUsageJSONLScanner

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let copilotDirectory = homeDirectory.appendingPathComponent(".copilot", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)

        self.scanner = SkillUsageJSONLScanner(
            directories: [
                copilotDirectory.appendingPathComponent("session-state", isDirectory: true),
            ],
            cacheURL: agentsDirectory
                .appendingPathComponent(".skilldeck-usage-cache-copilot-cli.json"),
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
        // Most events are tool calls and messages. Skip JSON decoding for them.
        guard line.contains("skill.invoked") else { return [] }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "skill.invoked",
              let payload = object["data"] as? [String: Any],
              let skillID = skillID(from: payload) else {
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

    /// SkillDeck keys usage by skill directory name (`Skill.id`), so prefer the directory that
    /// contains `SKILL.md`. Copilot's `name` is the frontmatter value and is used as a fallback
    /// when the path is missing or does not point to a `SKILL.md`.
    private static func skillID(from payload: [String: Any]) -> String? {
        if let path = payload["path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == "SKILL.md" {
                let directoryName = url.deletingLastPathComponent().lastPathComponent
                if !directoryName.isEmpty {
                    return directoryName
                }
            }
        }

        if let name = payload["name"] as? String, !name.isEmpty {
            return name
        }

        return nil
    }
}
```

**实现说明：**

- 无论 Task 1 结果如何，注释都保持中性的 “skill invocation” / detected invocation 描述；不得使用 “successful skill load” / “成功加载” 等更强的表述。
- 复用 `SkillUsageJSONLScanner`，自动获得按文件指纹缓存、失败保留、并发/actor 语义和聚合逻辑。
- `line.contains("skill.invoked")` 只是廉价预过滤；真正的类型判断由 JSON 解析后的 `type` 字段完成，避免把正文提及该字符串的消息计入。
- 不传入 `parserVersion`，使用默认值 1。后续如果修改解析语义，再像 `CodeBuddySkillUsageService` 一样设置 Provider 专属版本号，避免迫使其他 Agent 重新扫描。
- `data.path` 优先于 `data.name`，因为 SkillDeck 的 `Skill.id` 在 `Skill.swift` 中明确定义为目录名。

---

## Task 3: 注册默认 Provider

- [ ] 修改 `Sources/SkillDeck/Services/SkillUsage/SkillUsageProvider.swift`，在工厂中加入新 Provider：

```diff
 enum SkillUsageProviderFactory {
     static func makeDefaultProviders() -> [any SkillUsageProvider] {
         [
             CodexSkillUsageService(),
             ClaudeCodeSkillUsageService(),
+            CopilotSkillUsageService(),
             CodeBuddySkillUsageService(),
             QoderSkillUsageService(),
             OpenCodeSkillUsageService(),
         ]
     }
 }
```

注册后：

- `SkillManager.loadSkillUsage()` 会并发扫描 Copilot CLI 历史。
- `isSkillUsageSupported(.copilotCLI)` 返回 `true`。
- `AgentToggleView` 会自动渲染 Copilot CLI 行的 usage 状态。

---

## Task 4: 写单元测试

- [ ] 新建 `Tests/SkillDeckTests/CopilotSkillUsageServiceTests.swift`，内容如下：

```swift
import Foundation
import XCTest

@testable import SkillDeck

final class CopilotSkillUsageServiceTests: XCTestCase {
    func testScanCountsSkillInvokedEventsOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let session = fixture.root.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let lines = [
            try skillInvoked(
                timestamp: "2026-10-21T09:00:00.123Z",
                name: "skilldeck",
                path: "/Users/test/.copilot/skills/skilldeck/SKILL.md"
            ),
            // The directory name identifies the skill in SkillDeck, even when the
            // frontmatter name differs from the folder name.
            try skillInvoked(
                timestamp: "2026-10-21T09:01:00.123Z",
                name: "Display Name",
                path: "/Users/test/.agents/skills/gzh-design/SKILL.md"
            ),
            // Older or plugin events may omit the path; the name is a safe fallback.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:00.123Z",
                name: "pdf",
                path: nil
            ),
            // A valid path wins even when the frontmatter name is empty.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:30.123Z",
                name: "",
                path: "/Users/test/.agents/skills/path-only/SKILL.md"
            ),
            // A path that is not a SKILL.md falls back to a non-empty name.
            try skillInvoked(
                timestamp: "2026-10-21T09:02:45.123Z",
                name: "fallback-skill",
                path: "/Users/test/notes/README.md"
            ),
            // Other event types mentioning the word "skill.invoked" must not count.
            try jsonLine([
                "type": "user.message",
                "timestamp": "2026-10-21T09:03:00.123Z",
                "data": ["content": "What does skill.invoked mean?"],
            ]),
            try jsonLine([
                "type": "tool.execution_start",
                "timestamp": "2026-10-21T09:03:30.123Z",
                "data": ["toolName": "skill", "arguments": ["name": "ghost"]],
            ]),
            // Missing data, empty name/path, and malformed lines are ignored.
            try jsonLine([
                "type": "skill.invoked",
                "timestamp": "2026-10-21T09:04:00.123Z",
            ]),
            try skillInvoked(
                timestamp: "2026-10-21T09:04:30.123Z",
                name: "",
                path: ""
            ),
            // Same skill invoked again later: lastDetectedAt must keep the newest timestamp.
            try skillInvoked(
                timestamp: "2026-10-21T09:05:00.123Z",
                name: "skilldeck",
                path: "/Users/test/.copilot/skills/skilldeck/SKILL.md"
            ),
            "{ malformed json",
        ]
        try writeJSONL(lines, to: session.appendingPathComponent("events.jsonl"))

        let result = await CopilotSkillUsageService(
            historyDirectories: [fixture.root],
            cacheURL: fixture.root.appendingPathComponent("cache.json")
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 1)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertEqual(result.records["skilldeck"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["gzh-design"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["pdf"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["path-only"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records["fallback-skill"]?.detectedInvocationCount, 1)
        XCTAssertEqual(result.records.count, 5)
        XCTAssertNil(result.records["Display Name"])
        XCTAssertNil(result.records["ghost"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.records["skilldeck"]?.lastDetectedAt,
            formatter.date(from: "2026-10-21T09:05:00.123Z")
        )
    }

    func testDefaultProviderFactoryIncludesCopilotCLI() {
        let providers = SkillUsageProviderFactory.makeDefaultProviders()

        XCTAssertTrue(providers.contains { $0.agentType == .copilotCLI })
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDeckCopilotMissing-\(UUID().uuidString)", isDirectory: true)

        let result = await CopilotSkillUsageService(historyDirectories: [missing]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    private func skillInvoked(
        timestamp: String,
        name: String,
        path: String?
    ) throws -> String {
        var data: [String: Any] = ["name": name]
        if let path {
            data["path"] = path
        }
        return try jsonLine([
            "type": "skill.invoked",
            "timestamp": timestamp,
            "data": data,
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
                .appendingPathComponent("SkillDeckCopilotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

**覆盖点：**

- 只统计 `skill.invoked`，忽略其他事件类型。
- 合法路径优先于 frontmatter name；路径父目录与 `data.name` 不一致时按路径计数。
- 合法路径 + 空 `name` 仍按路径计数。
- 缺失 `path` 或路径末级不是 `SKILL.md` 时回退到非空 `name`。
- 缺失 `data`、空 `name` + 空 `path`、损坏 JSON 不计数、不崩溃。
- 时间戳解析和 `lastDetectedAt` 取最大值。
- 历史目录缺失时返回空结果且不报失败。
- 默认 `SkillUsageProviderFactory` 包含 `.copilotCLI`，防止只实现 Service 却忘记注册。

---

## Task 5: 构建与自动化测试

- [ ] 编译：

```bash
swift build
```

- [ ] 只跑新增测试：

```bash
swift test --filter CopilotSkillUsageServiceTests
```

预期：3 个测试通过。

- [ ] 跑全量测试：

```bash
set -o pipefail
swift test 2>&1 | tail -5
```

预期：223 个测试全部通过（220 基线 + 3 新增）。

- [ ] 检查 diff：

```bash
git status --short
git diff
```

预期：实现相关的文件只有 3 个（1 个修改、2 个新增），无无关改动；本计划文档本身应在实现前单独提交或忽略。

---

## Task 6: 手工验证

- [ ] 统计本机真实事件数，作为 UI 对照值：

```bash
python3 - <<'EOF'
import collections
import glob
import json
import os

def skill_id(data):
    """Mirror CopilotSkillUsageService.skillID(from:): path first, then name."""
    path = data.get('path')
    if isinstance(path, str) and path:
        if os.path.basename(path) == 'SKILL.md':
            parent = os.path.basename(os.path.dirname(path))
            if parent:
                return parent

    name = data.get('name')
    if isinstance(name, str) and name:
        return name

    return None

counts = collections.Counter()
for file_path in glob.glob(os.path.expanduser('~/.copilot/session-state/*/events.jsonl')):
    with open(file_path, encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if '"skill.invoked"' not in line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get('type') != 'skill.invoked':
                continue

            data = event.get('data')
            if not isinstance(data, dict):
                continue

            identifier = skill_id(data)
            if identifier:
                counts[identifier] += 1

for name, count in counts.most_common():
    print(f"{count:4d}  {name}")
EOF
```

- [ ] 启动应用：

```bash
swift run SkillDeck
```

- [ ] 打开一个本机存在的 skill 详情页，例如 `ponytail` 或 `swiftui-expert-skill`，确认 Copilot CLI 行显示 `N uses`，且数字与上一步脚本输出一致（计数会随新会话增长，不要求固定值）。
- [ ] 选中一个从未被 Copilot 调用的 skill，确认显示 `Never detected` 而不是空白。
- [ ] 确认其他 Agent 行（Claude Code、Codex、CodeBuddy、Qoder、OpenCode）的统计仍正常显示。
- [ ] 重启应用，确认第二次扫描命中缓存（启动速度无明显变化），计数保持一致。

---

## 5. 风险与边界

| 风险 | 影响 | 处理 |
|---|---|---|
| 旧版 Copilot CLI 不写 `skill.invoked` | 旧历史计数为 0 或偏少 | 明确文案是 best-effort；不伪造数据。后续可评估旧日志格式再补适配 |
| 会话历史被清理或关闭 | 计数偏少 | 与现有 Agent 的本地历史语义一致；缓存只保留仍可枚举的文件 |
| 项目级/插件 skill 与用户级 skill 同名 | 可能把调用记到同名 SkillDeck skill 上 | 与其他 Provider 一致，属于已知 best-effort 边界；后续可按可信目录白名单收紧 |
| 单个事件包含完整 `content`，行可能很大 | 内存/解析开销 | `SkillUsageLineReader` 逐行读取；先做字符串预过滤再做 JSON 解析；文件指纹缓存避免重复重扫 |
| 同一事件重复写盘 | 重复计数 | 本机 69 条事件 id 全部唯一；当前不改 Scanner。如未来出现重复，可增加事件 id 去重 |
| 失败调用是否也写 `skill.invoked` | 无法由单次样本覆盖所有失败路径 | 指标始终定义为 detected invocation count；Task 1 只在同一会话内观察「未知 skill」场景（含正向对照），结论限定在该场景，不外推，也不改用成功语义 |
| `data.name` 与路径父目录不一致 | 可能统计到不同 ID | 以路径父目录为准；测试显式覆盖两者的优先级，手工脚本采用同一规则 |
| 扫描 `~/.copilot` 权限不足 | 显示 unreadable 警告 | 复用 `SkillUsagePathProbe` 与 Scanner 的失败语义，不会误报为 unavailable |

---

## 6. 后续可选增强

- **可信目录过滤**：只统计 `~/.copilot/skills`、`~/.claude/skills`、`~/.agents/skills` 等 SkillDeck 管理的目录，降低同名冲突。
- **按事件 id 去重**：如果 Copilot 未来出现重复写入，可在缓存格式中加入事件 id 集合。
- **旧版日志适配**：验证 `~/.copilot/logs/session-*.log` 或 `session-store.db` 是否含 skill 记录，作为 `events.jsonl` 不可用时的补充来源。
- **来源维度展示**：利用 `trigger` / `source` / `pluginName` 区分手动、模型主动和插件调用；当前 UI 只有总次数，暂不需要。
- **事件类型监控**：在 Copilot CLI 升级后检查 `skill.invoked` 是否改名为 `skill.loaded` 等；如有变化，bump Provider 专属 `parserVersion`。

---

## 7. 自检清单

- [ ] Task 1 的语义观察已执行，正向对照（已知有效 skill）在事件文件中命中，观察结论与正向对照结果已写入 PR 描述或提交说明，且指标保持 detected invocation 语义。
- [ ] 没有修改 `SkillUsageJSONLScanner`、`SkillUsageLogCache`、`SkillManager`、UI 或本地化。
- [ ] 新 Provider 的 `agentType` 是 `.copilotCLI`。
- [ ] 扫描目录只有 `~/.copilot/session-state`，没有扫描整个 `~/.copilot`。
- [ ] 缓存文件名是 `.skilldeck-usage-cache-copilot-cli.json`。
- [ ] `skillID` 规则与第 2 节一致：合法 `SKILL.md` 路径优先（即使 `name` 为空），否则回退到非空 `name`，两者都不可用才忽略。
- [ ] 测试显式覆盖「name 与目录名不一致」「合法路径 + 空 name」「无效路径 + 非空 name」「两者都为空」。
- [ ] 默认 Provider 工厂包含 `.copilotCLI`，并有测试断言。
- [ ] 忽略非 `skill.invoked` 事件、缺失字段和损坏 JSON。
- [ ] 新测试覆盖 count、ID 优先级、timestamp、缺失历史、工厂注册五类行为。
- [ ] 全量测试通过，且其他 Agent 的测试结果不变。
- [ ] 手工对照脚本与 Service 使用同一 ID 规则，UI 数字与脚本输出一致。
