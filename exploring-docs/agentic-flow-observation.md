# Agentic Flow Observation — Session Data & Harness Model

Findings from exploring the Kilo Code plugin source for ways to observe, extract, and back-analyze chat/agent sessions — especially the tool/agentic loop that an OpenAI (or local proxy) HTTP log alone does not cover.

Also summarizes the **hard-coded harness shape** you need when interpreting those sessions. The precise extract of code-only constraints lives in [`hard-coded-agent-constraints.md`](./hard-coded-agent-constraints.md).

---

## Goal

When sessions fail to produce expected results (e.g. tools not applied, incomplete edits, weak exploration), we need observation material beyond the LLM HTTP request/response. The LLM proxy captures what went to the model; the agentic flow is also about:

- Which tools were invoked and with what arguments
- What tool results were returned into the conversation
- Whether tools were denied / blocked in the UI
- MCP / command / browser side effects
- How the conversation state evolved across turns
- Whether a failure was **model behavior** vs **harness structure** (one tool/turn, native-only protocol, self-reported completion, truncated search/read, context condense)

**Verdict:** Meaningful local observation already exists. No new code is required to start analyzing sessions. Use the hard-coded constraints doc to separate “the agent chose badly” from “the harness cannot do X.”

---

## Hard-coded harness model (summary)

Full tables and source pointers: [`hard-coded-agent-constraints.md`](./hard-coded-agent-constraints.md).

### Loop shape

```
user message
  → initiateTaskLoop (while !abort)
    → recursivelyMakeClineRequests (stack-based turns)
      → system prompt + history + environment_details
      → streaming api.createMessage(...)
      → presentAssistantMessage (execute at most one tool)
      → tool_result (or noToolsUsed nudge) → next turn
```

Primary runtime: `src/core/task/Task.ts`, `src/core/assistant-message/presentAssistantMessage.ts`.  
`packages/agent-runtime/` only hosts this same `Task` via IPC — it does not define a second loop.

| Structural fact | Implication for session analysis |
|-----------------|----------------------------------|
| **One tool executed per assistant message** | Parallel/multi-tool experiment is **runtime-disabled** (`parallelToolCallsEnabled = false`, `isMultipleNativeToolCallsEnabled = false`). Extra tools in the same message are skipped with an error string in the tool result / UI. |
| **Native tool protocol for new tasks** | `resolveToolProtocol.ts` ignores profile `toolProtocol`. Chat prose / XML tags are **not** applied as edits. Look for `tool_use` / native tool calls in API history, not for diffs only in `say: "text"`. |
| **Must tool-call or get nudged** | Zero-tool assistant turns get injected `noToolsUsed` text; after grace (`consecutiveNoToolUseCount >= 2`) this counts as mistakes. |
| **Completion is self-reported** | `attempt_completion` does not verify all planned files were edited. A “done” session can still have untouched files. |
| **No hard max turn count** | `MAX_REQUESTS_PER_TASK` is commented, not implemented. Long sessions end by abort, mistake limit, or auto-approval caps — not a fixed iteration ceiling. |
| **Streaming-only** | Failures mid-stream (abort, empty first chunk, provider disconnect) show up as incomplete assistant turns / retries, not a separate non-streaming path. |

### Exploration / write caps that show up in tool results

When a `tool_result` looks “thin,” check these before blaming the model:

| Tool / area | Hard limit (code) | Notes |
|-------------|-------------------|-------|
| `list_files` | **200** files | Not a setting (unlike `maxWorkspaceFiles` for first-turn `environment_details`) |
| `search_files` | **300** results; lines cut at **500** chars | Message often says “Showing first 300…” |
| `read_file` | **60%** of remaining tokens; hard block near **80%** of context | Bypass only with `allowVeryLargeReads` |
| Code index | Skip files **> 1 MB**; chunks ~**1000** chars; scan ≤ **50k** paths | Semantic search needs status `Indexed` |
| Context condense | Keeps last **3** messages (`N_MESSAGES_TO_KEEP`) | Truncation fallback hides ~**50%** of the middle |
| ApplyDiff | `BUFFER_LINES = 40` match window | Fuzzy threshold *is* a setting |

Prompt/mode tuning (what *is* adjustable) is covered in [`kilo-code-prompts-write-update.md`](./kilo-code-prompts-write-update.md). Discovery extension paths (MCP, deps catalog): [`kilo-code-extension.md`](./kilo-code-extension.md).

---

## Primary source: per-task folders on disk

Each chat/task persists under extension global storage:

```
{globalStorage}/tasks/{taskId}/
  api_conversation_history.json   # Full LLM transcript (tool_use + tool_result)
  ui_messages.json                # Chat UI messages (approvals, MCP, metrics)
  task_metadata.json              # File-context tracker metadata
  checkpoints/                    # Shadow-git workspace snapshots
```

### Typical paths

| Environment | Default location (Linux) |
|-------------|--------------------------|
| VS Code | `~/.config/Code/User/globalStorage/kilocode.kilo-code/tasks/` |
| VS Code Insiders / Cursor / other hosts | Same pattern under that product’s `globalStorage` |

Override with VS Code setting:

- `kilo-code.customStoragePath` — redirect all task storage to a known directory

Implementation references:

- `src/utils/storage.ts` — `getStorageBasePath()`, `getTaskDirectoryPath()`
- `src/shared/globalFileNames.ts` — file name constants
- `src/core/task-persistence/apiMessages.ts` — API history read/write
- `src/core/task-persistence/taskMessages.ts` — UI messages read/write

---

## Dual histories (what to analyze)

### A. `api_conversation_history.json` — canonical LLM / tool transcript

Written by `Task.saveApiConversationHistory()` → `saveApiMessages()`.

Contains Anthropic-style (and extended) messages:

- Assistant: text, `tool_use` / native tool calls, thinking / reasoning blocks
- User: `tool_result` blocks (with `tool_use_id`), environment details, user text/images
- Condense / truncation markers when context was compacted
- Injected `noToolsUsed` (or equivalent) user/system nudge text after empty-tool turns

**This is the main artifact for “why did tooling go wrong?”**  
It shows the full agentic loop: model decided tool X → tool returned Y → next model turn.

Because the harness enforces **one tool per turn**, a healthy multi-step task looks like many short assistant→tool_result pairs — not one assistant message with a batch of tools.

Markdown export walks this history and formats `[Tool Use: name]` / tool results  
(`src/integrations/misc/export-markdown.ts`).

### B. `ui_messages.json` — chat UI / side effects

`ClineMessage[]` via `saveClineMessages()`. Schema: `packages/types/src/message.ts`.

| Kind | Examples |
|------|----------|
| `ask: "tool"` | Approval UI; `text` is JSON matching tool params (path, diff, content, …) |
| `ask: "command"`, `use_mcp_server`, `followup`, … | Other approvals |
| `say: "text"`, `reasoning`, `completion_result` | Visible assistant output |
| `say: "api_req_started"` | Metrics JSON (tokens, cost, protocol — **not** full request body) |
| `say: "mcp_server_request_started"` / `"mcp_server_response"` | MCP I/O in UI |
| `say: "command_output"`, `browser_action*`, `checkpoint_saved`, `condense_context`, … | Other side effects |

Use UI history when the model transcript looks fine but the user/tool side failed (denied tools, bad command output, MCP errors shown only in the UI).

**Protocol hint:** `api_req_started` / task metadata may record whether the task is on native vs XML protocol (resumed legacy tasks can still be XML).

---

## Built-in extraction paths (no code changes)

| Action | How | What you get |
|--------|-----|----------------|
| **Debug open API/UI JSON** | Set `kilo-code.debug` = `true`; task header buttons “Open API History” / “Open UI History” | Prettified temp JSON of the two history files |
| **Export task as Markdown** | Task header download / History export | `kilo_code_task_*.md` from **API** history (tools formatted) |
| **Copy prompt** | Copy icon on task | Initial task text only |
| **Error diagnostics** | Error row “download diagnostics” | JSON with error meta + **full API history** |
| **History panel** | Reopen past tasks | As long as auto-cleanup hasn’t purged them |
| **Output channel** | View → Output → **Kilo-Code** | Operational/extension logs (not full transcripts) |
| **Filesystem** | Copy `tasks/{taskId}/` | Full raw JSON + checkpoints |
| **Cloud share / session sync** | When authenticated with Kilo cloud | Share/sync of session blobs; local share UI partly disabled |

Debug open handlers: `openDebugApiHistory` / `openDebugUiHistory` in  
`src/core/webview/webviewMessageHandler.ts`  
UI buttons gated by `debug` state in `webview-ui/src/components/chat/TaskActions.tsx`.

Setting:

```json
"kilo-code.debug": true
```

(`src/package.json` contributes this configuration.)

---

## Relation to an OpenAI / local proxy log

| Layer | Captured by proxy? | Captured in task files? |
|-------|--------------------|-------------------------|
| Full chat/completions (or Responses) HTTP payloads | Yes | Message content after provider transforms → `api_conversation_history.json` |
| Streaming chunks, HTTP headers, raw SSE | Yes (if logged) | **No** |
| Tool rounds as conversation state | Only if embedded in the LLM messages | **Yes** — `tool_use` / `tool_result` in API history |
| UI denials / approvals / command output presentation | No | **Yes** — `ui_messages.json` |
| Token/cost usage | Sometimes from response | Merged into `api_req_started` + history aggregates |
| Provider `tools` / `tool_choice` / `parallel_tool_calls` | Yes (request body) | Partially reflected in what tools actually ran; parallel is always off in metadata |

**Implication:** Local history is a **post-processed conversation model**, not a byte-accurate HTTP log.  
For wire-level debugging of *all* outbound HTTP (not only the LLM proxy), there is also:

- `kilo-code.debugProxy.enabled`
- `kilo-code.debugProxy.serverUrl` (default `http://127.0.0.1:8888`)
- `kilo-code.debugProxy.tlsInsecure`

Implementation: `src/utils/networkProxy.ts`. Intended primarily when the extension runs in F5/debug mode. A workplace OpenAI proxy is usually enough for the LLM hop; task JSON is needed for the tool loop.

When comparing proxy vs API history: the proxy may show the model *emitting* multiple `tool_calls` in one response; the harness will still execute only the first and reject the rest — that mismatch is expected with current code.

---

## Logging & telemetry (secondary)

### Output / file logs

| Path / channel | Purpose |
|----------------|---------|
| VS Code Output **Kilo-Code** | Operational logs (`src/utils/outputChannelLogger.ts`) |
| `$TMPDIR/kilo-code-messages.log` | IPC/API message log when socket logging enabled |
| `$TMPDIR/kilo-debug-{api\|ui}-*.json` | Temp files from debug history buttons |
| `$TMPDIR/kilo-diagnostics-*.json` | Error diagnostics export |
| `~/.roo/cli-debug.log` | CLI debug log (`packages/core/src/debug-log/`) |

### Telemetry

- Package: `@roo-code/telemetry` → PostHog in production; debug client in development
- Events include task lifecycle, `LLM_COMPLETION`, `TOOL_USED`, checkpoints, etc. (`packages/types/src/telemetry.ts`)
- **Full message bodies are not sent** (`TASK_MESSAGE` excluded / commented out)
- Useful for aggregate metrics; **not** a substitute for local task JSON when analyzing a single bad session

### MCP

- MCP tool calls appear in UI history (`ask: use_mcp_server`, `say: mcp_server_*`) and as tool results in API history
- Connection errors: in-memory `errorHistory` in `McpHub` (≤100) — **not** persisted as a wire dump
- No dedicated MCP JSON-RPC pcap-style log file
- MCP tools are still subject to the **one tool per message** gate (same as built-in tools)

---

## Checkpoints & session sync

- **Checkpoints:** `{storage}/tasks/{taskId}/checkpoints/` via `RepoPerTaskCheckpointService` — workspace snapshots, UI marker `say: "checkpoint_saved"`
- **Session manager:** can sync `api_conversation_history`, `ui_messages`, metadata to Kilo cloud when enabled (`src/shared/kilocode/cli-sessions/`)
- **Auto-purge:** `src/services/auto-purge/` may delete old task dirs by retention settings — copy important sessions before cleanup

---

## Practical workflow for back-analysis

1. Point storage somewhere convenient (`kilo-code.customStoragePath`), or locate `globalStorage/.../tasks/`.
2. For a bad session, take **`api_conversation_history.json`** as the primary timeline of tool calls/results.
3. Diff that against the OpenAI/proxy log for the same turns (prompt construction vs raw wire).
4. Use **`ui_messages.json`** when the model looks fine but the user/tool side failed (denied tools, command/MCP failures).
5. Enable `kilo-code.debug` for live sessions so those JSONs open in one click.
6. Optionally export Markdown for human-readable review; keep JSON for scripting.
7. When classifying root cause, check [`hard-coded-agent-constraints.md`](./hard-coded-agent-constraints.md) — e.g. truncated `search_files`, one-tool skip messages, condense markers, native-only missed edits.

### Suggested questions when reading a failed session

**Harness / protocol**

- Did the model emit a native `tool_use` / `tool_call` for the intended edit, or only chat text?
- Did a later tool in the same assistant message get the “Only one tool may be used per message” skip?
- Was this a resumed XML-era task or a new native-only task?
- Right after a zero-tool assistant turn, is there an injected `noToolsUsed` / “You did not use a tool” user message?

**Tool results / exploration**

- Did a `tool_result` return an error / empty / truncated payload (`list_files` 200, `search_files` 300, read budget)?
- Was a tool ask denied or never approved in the UI?
- Was context condensed (`condense_context`) or truncated right before quality dropped?
- For dependency/API mistakes: did the session only ever `read_file` on `pom.xml`, with no on-disk sources/index hits?

**Completion / edits**

- Did `attempt_completion` fire while some planned paths never appeared in any edit tool call?
- Do proxy request bodies match the API history content for that turn (provider transform mismatch)?
- Which edit tools were in the schema for that model/mode (see prompts-write-update doc) vs which ones the model tried to name in prose?

---

## Gaps (would need new features)

1. One-click **export bundle** of both `ui_messages.json` + `api_conversation_history.json` (plus optional timeline)
2. Structured **JSON/JSONL transcript** optimized for external analysis
3. Persisted **MCP protocol** request/response dump
4. **HTTP archival** of LLM traffic without F5 MITM / external proxy
5. Re-enabled **Cloud Share** UI (backend exists; UI largely commented out)
6. **Import** of an exported conversation into a new task
7. Unified **session report** combining UI, API, checkpoints, MCP errors
8. Harness changes that would alter observation patterns: multi-tool/parallel execution, completion verification (files actually edited), higher list/search caps — see constraints doc (code-change only today)

These are nice-to-haves; they are not blockers for starting analysis today.

---

## Key file index

| Area | Paths |
|------|-------|
| Persistence | `src/core/task-persistence/*`, `src/utils/storage.ts`, `src/shared/globalFileNames.ts` |
| Task runtime / loop | `src/core/task/Task.ts`, `src/core/assistant-message/presentAssistantMessage.ts` |
| Protocol lock | `src/utils/resolveToolProtocol.ts` |
| noToolsUsed / responses | `src/core/prompts/responses.ts` |
| Message types | `packages/types/src/message.ts`, `packages/types/src/history.ts` |
| Export | `src/integrations/misc/export-markdown.ts`, `webview-ui/.../TaskActions.tsx` |
| Diagnostics | `src/core/webview/diagnosticsHandler.ts` |
| Telemetry | `packages/telemetry/*`, `packages/types/src/telemetry.ts` |
| Sessions | `src/shared/kilocode/cli-sessions/**` |
| Logging | `src/utils/outputChannelLogger.ts`, `src/utils/networkProxy.ts` |
| MCP | `src/services/mcp/McpHub.ts`, `src/core/tools/UseMcpToolTool.ts` |
| Handler hub | `src/core/webview/webviewMessageHandler.ts` |
| Hard limits (list/search/read/index/context) | See [`hard-coded-agent-constraints.md`](./hard-coded-agent-constraints.md) |

---

## Bottom line

You do not need new plugin features to start observing agentic sessions. The richest local material is already on disk:

1. **`api_conversation_history.json`** — tool/agent loop (primary)
2. **`ui_messages.json`** — approvals, MCP/command presentation, metrics (secondary)
3. **OpenAI/local proxy log** — raw LLM wire traffic (complements 1)
4. **[`hard-coded-agent-constraints.md`](./hard-coded-agent-constraints.md)** — which failures are structural vs tunable

Together these cover prompt construction, tool calls/results, UI-side failures, and the fixed harness rules that explain many “why didn’t it…?” outcomes without assuming a settings knob exists.
