# Hard-Coded Agent Constraints

Precise extract of Kilo Code harness facts that define default agent behavior while running (analyzing, finding, writing code). These cannot be changed via settings, agent modes, custom instructions, or experiments in normal use — only via code changes (or a fork).

Related docs:

- [`agentic-flow-observation.md`](./agentic-flow-observation.md) — how to observe a live/past session against this model
- [`kilo-code-prompts-write-update.md`](./kilo-code-prompts-write-update.md) — what *can* be tuned via prompts/modes vs harness
- [`kilo-code-extension.md`](./kilo-code-extension.md) — code-discovery extension paths (MCP, rules, deps catalog)

---

## Mental model

```
┌────────────────────────────────────────────────────────────┐
│ HARD (code-only)                                           │
│  • Single streaming turn loop                              │
│  • Exactly 1 tool executed per assistant message           │
│  • Native tool_calls only (new tasks)                      │
│  • Must tool-call or get noToolsUsed nudge                 │
│  • Completion = model calls attempt_completion             │
│  • Exploration = list/grep/read/index over workspace files │
│  • Fixed tool result caps & context compaction rules       │
└────────────────────────────────────────────────────────────┘
         ▲ modes / settings only tune prompts + tool set
```

---

## 1. Agentic loop structure

**Primary files:** `src/core/task/Task.ts`, `src/core/assistant-message/presentAssistantMessage.ts`

```
user message
  → initiateTaskLoop (while !abort)
    → recursivelyMakeClineRequests (explicit stack, not deep call recursion)
      → build user content + environment_details
      → api.createMessage(systemPrompt, history)   // streaming only
      → parse text / native tool_call* chunks
      → presentAssistantMessage (execute tools sequentially)
      → wait for userMessageContentReady
      → next API turn with tool_result(s) (or noToolsUsed nudge)
```

| Fact | Detail | Change via settings? |
|------|--------|----------------------|
| One main prompt per turn | System prompt + conversation history → one assistant response | No |
| Tools live in the response | Text and/or tool calls in the same turn; not a separate planner agent | No |
| Streaming-only | `ApiHandler.createMessage` returns `ApiStream`; providers pass `stream: true` | No |
| No hard max iterations | Comment mentions `MAX_REQUESTS_PER_TASK` but it is **not implemented**; outer loop is `while (!abort)` | No (auto-approval request/cost caps are settings) |
| Stack-based turns | Avoids unbounded call-stack recursion; tools still advanced via `presentAssistantMessage` | No |
| Agent-runtime is not a different loop | `@kilocode/agent-runtime` hosts the same extension `Task` via IPC | No |

**Completion:** the model must call `attempt_completion`. The harness does **not** verify that planned files were edited. Plain chat text does not end the loop as success.

**No-tool turns:** if the assistant returns content with zero tools, the loop injects fixed `formatResponse.noToolsUsed(...)` text and continues (`src/core/prompts/responses.ts`).

---

## 2. One tool per turn (runtime-enforced)

Confirmed hard-disabled at **both** API and execution layers. Prompt text and the `multipleNativeToolCalls` experiment do **not** override this.

| Layer | Behavior | Location |
|-------|----------|----------|
| API request | `parallelToolCallsEnabled = false` always | `Task.ts` (~4698–4712) |
| Executor | `isMultipleNativeToolCallsEnabled = false` always | `presentAssistantMessage.ts` (~569–686) |
| Extra tools same message | Skipped: *"Only one tool may be used per message."* | same |
| Prompt | “exactly one tool call per assistant response” | mode prompts / `objective.ts` / tool-use sections |
| `tool_choice` | Always `"auto"` when tools are included | `Task.ts` |

Implication: multi-file edits need many round-trips. Models often describe remaining files in chat and call `attempt_completion` early.

Even if multi-tool were re-enabled in code, current design would still execute them **sequentially**, not in parallel.

---

## 3. Tool protocol lock

`src/utils/resolveToolProtocol.ts`:

| Precedence | Behavior |
|------------|----------|
| 1. Task lock | Resumed tasks keep original protocol (XML or native) |
| 2. New tasks | **Always native** (`TOOL_PROTOCOL.NATIVE`) |

- Profile `toolProtocol` and model `defaultToolProtocol` are **ignored** for new tasks.
- XML is deprecated; chat prose / XML tags are not parsed into edits on new tasks.
- If the model writes a diff only in chat text → nothing is applied.

---

## 4. Must use a tool / mistake handling

| Constraint | Value | Configurable? |
|------------|-------|---------------|
| Grace before “no tools” mistake path | `consecutiveNoToolUseCount >= 2` | **No** |
| Forced nudge text | Fixed `noToolsUsed` message | **No** |
| Consecutive mistake stop | Default **3** | **Yes** (`consecutiveMistakeLimit`; `0` = unlimited) |
| Identical tool repetition detector | Tied to mistake limit (default 3) | Partially (via mistake limit) |
| Auto-approval max requests/cost | — | **Yes** (`Infinity` if unset) |

---

## 5. Code exploration / finding

| Mechanism | Hard limit / fact | Configurable? | Source |
|-----------|-------------------|---------------|--------|
| First-turn workspace listing in `environment_details` | Default **200** paths | **Yes** (`maxWorkspaceFiles`) | `getEnvironmentDetails.ts` |
| `list_files` | Cap **200** files | **No** | `ListFilesTool.ts` |
| `search_files` (ripgrep) | **300** results; lines truncated at **500** chars | **No** | `services/ripgrep/index.ts` |
| `read_file` token budget | **60%** of remaining context for file content | **No** | `FILE_READ_BUDGET_PERCENT = 0.6` |
| Absolute read size gate | Block when file would exceed **80%** of model context | Bypass only via `allowVeryLargeReads` | `tools/kilocode.ts` |
| Default max lines / concurrent file reads | 500 lines / 5 files | **Yes** | `maxReadFileLine`, `maxConcurrentFileReads` |
| Stuck cwd | Tools take `path`; lasting `cd` is not supported | No (prompt + tool design) | RULES / tools |
| No fixed explore phase | Model chooses tools each turn; no “N discovery steps before edit” | No | harness |

### Code index (when enabled)

Constants in `src/services/code-index/constants/index.ts`:

| Constant | Value | Configurable? |
|----------|-------|---------------|
| `MAX_FILE_SIZE_BYTES` | **1 MB** (larger files skipped) | No |
| `MAX_LIST_FILES_LIMIT_CODE_INDEX` | **50,000** paths when scanning | No |
| `MAX_BLOCK_CHARS` / tolerance | **1000** (+15%) | No |
| `MIN_BLOCK_CHARS` | **50** | No |
| `PARSING_CONCURRENCY` | **10** | No |
| Search result count | Default **50**, range 10–200 | **Yes** (bounded) |
| Min similarity score | Default **0.4**, range 0–1 | **Yes** (bounded) |

Architectural limits (not settings):

- Index covers **workspace files on disk** that tree-sitter (or fallback chunking) can parse — not IntelliJ PSI, Maven classpath, or External Libraries.
- Reading `pom.xml` does not resolve JARs/sources; no built-in dependency API download.
- Semantic search only works when index status is `Indexed`.

---

## 6. Code writing

| Fact | Detail | Configurable? |
|------|--------|---------------|
| Edits only via tools | Native `tool_call` → tool handler → (approval) → disk | No |
| Chat text never applied | No “chat diff → apply” fallback | No |
| Completion self-reported | `attempt_completion` does not check all planned files were edited | No |
| ApplyDiff match window | `BUFFER_LINES = 40` | No |
| ApplyDiff / patch / replace formats | Fixed SEARCH/REPLACE, patch hunks, old/new string, full file, Morph | No (which tools appear is filtered) |
| Multi-file `apply_diff` | Experiment; default **off** | Experiment flag |
| Tool set per session | Filtered by mode × model × Fast Apply × settings | Partially |

Which edit tools appear *is* policy-tunable (mode, GPT-5.1 prefs, Fast Apply). The apply mechanisms and completion gap are not. See [`kilo-code-prompts-write-update.md`](./kilo-code-prompts-write-update.md).

---

## 7. Context management

| Mechanism | Value | Configurable? | Source |
|-----------|-------|---------------|--------|
| Buffer before condense/truncate | **10%** (`TOKEN_BUFFER_PERCENTAGE`) | No | `context-management/index.ts` |
| Sliding-window fallback | Hide **50%** of middle messages (keep first) | No | same |
| Messages kept after condense | **`N_MESSAGES_TO_KEEP = 3`** | No | `condense/index.ts` |
| Condense threshold % | Default / per-profile | **Yes** (`autoCondenseContext*`) | settings |
| Context-window error retries | **3** (`MAX_CONTEXT_WINDOW_RETRIES`) | No | `Task.ts` |
| Forced reduction keep ratio | Keep **75%** | No | `Task.ts` |
| XML parser accumulator | 1 MB message / 100 KB per param | No | `AssistantMessageParser.ts` |

---

## 8. System prompt: fixed vs mode-tunable

Assembled in `src/core/prompts/system.ts`. Roughly **~90% shared** across built-in modes.

**Fixed structural sections (code):** TOOL USE rules, tool guidelines, capabilities, modes list, skills, rules, system info, **OBJECTIVE** (one tool at a time; must `attempt_completion`).

**Mode / user tunable:** `roleDefinition`, custom instructions, tool **groups**, custom modes, `.kilocode/rules`, `AGENTS.md`, optional file override `system-prompt-{mode}` (replaces catalog — footgun).

Objective text (`src/core/prompts/sections/objective.ts`) hard-codes iterative one-tool-at-a-time behavior and `attempt_completion` as the terminal tool.

---

## 9. Quick reference: code-change only vs settings

### Code-change only (this document)

1. One tool executed per assistant message (+ parallel API flag off)
2. Native protocol forced for new tasks
3. Streaming-only agent loop; no max-turn constant
4. Self-reported `attempt_completion` (no edit-coverage check)
5. `list_files` = 200; `search_files` = 300 / 500-char lines
6. Read budget 60% remaining; hard block at 80% context (unless allow-very-large)
7. Index: 1 MB file cap, ~1000-char chunks, 50k path scan
8. Condense keeps last 3; truncate removes half the middle
9. ApplyDiff 40-line buffer; fixed edit formats
10. No Maven/JAR/External Library resolution in core harness

### Adjustable without forking

| Surface | Examples |
|---------|----------|
| Modes | Code vs Ask (no edits) vs Architect (`.md` only) |
| Custom instructions / rules | `.kilocode/rules`, `AGENTS.md`, org modes |
| Mistake / auto-approve limits | `consecutiveMistakeLimit`, request/cost caps |
| Read UX limits | `maxReadFileLine`, `maxConcurrentFileReads`, `maxWorkspaceFiles` |
| Index search knobs | result count, min score, enable/disable indexing |
| Fast Apply / diff settings | Which edit tools are exposed |
| Approvals / YOLO | Whether tools run without click |

---

## Key source files

| Area | Path |
|------|------|
| Outer loop / API metadata | `src/core/task/Task.ts` |
| Tool presentation / one-tool gate | `src/core/assistant-message/presentAssistantMessage.ts` |
| Protocol resolution | `src/utils/resolveToolProtocol.ts` |
| System prompt / objective | `src/core/prompts/system.ts`, `sections/objective.ts` |
| noToolsUsed text | `src/core/prompts/responses.ts` |
| List / search / read | `ListFilesTool.ts`, `services/ripgrep/index.ts`, `ReadFileTool.ts`, `helpers/fileTokenBudget.ts` |
| Code index constants | `src/services/code-index/constants/index.ts` |
| Context / condense | `src/core/context-management/index.ts`, `src/core/condense/index.ts` |
| Diff buffer | `src/core/diff/strategies/multi-search-replace.ts` |
| Environment details | `src/core/environment/getEnvironmentDetails.ts` |
