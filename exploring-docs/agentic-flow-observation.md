# Agentic Flow Observation — Extracting Session Data from Kilo Code

Findings from exploring the Kilo Code plugin source for ways to observe, extract, and back-analyze chat/agent sessions — especially the tool/agentic loop that an OpenAI (or local proxy) HTTP log alone does not cover.

---

## Goal

When sessions fail to produce expected results (e.g. tools not applied, incomplete edits, weak exploration), we need observation material beyond the LLM HTTP request/response. The LLM proxy captures what went to the model; the agentic flow is also about:

- Which tools were invoked and with what arguments
- What tool results were returned into the conversation
- Whether tools were denied / blocked in the UI
- MCP / command / browser side effects
- How the conversation state evolved across turns

**Verdict:** Meaningful local observation already exists. No new code is required to start analyzing sessions.

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

**This is the main artifact for “why did tooling go wrong?”**  
It shows the full agentic loop: model decided tool X → tool returned Y → next model turn.

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

**Implication:** Local history is a **post-processed conversation model**, not a byte-accurate HTTP log.  
For wire-level debugging of *all* outbound HTTP (not only the LLM proxy), there is also:

- `kilo-code.debugProxy.enabled`
- `kilo-code.debugProxy.serverUrl` (default `http://127.0.0.1:8888`)
- `kilo-code.debugProxy.tlsInsecure`

Implementation: `src/utils/networkProxy.ts`. Intended primarily when the extension runs in F5/debug mode. A workplace OpenAI proxy is usually enough for the LLM hop; task JSON is needed for the tool loop.

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

### Suggested questions when reading a failed session

- Did the model emit `tool_use` for the intended edit, or only chat text?
- Did a `tool_result` return an error / empty / truncated payload?
- Was a tool ask denied or never approved in the UI?
- Was context condensed (`condense_context`) right before quality dropped?
- Do proxy request bodies match the API history content for that turn (provider transform mismatch)?

---

## Gaps (would need new features)

1. One-click **export bundle** of both `ui_messages.json` + `api_conversation_history.json` (plus optional timeline)
2. Structured **JSON/JSONL transcript** optimized for external analysis
3. Persisted **MCP protocol** request/response dump
4. **HTTP archival** of LLM traffic without F5 MITM / external proxy
5. Re-enabled **Cloud Share** UI (backend exists; UI largely commented out)
6. **Import** of an exported conversation into a new task
7. Unified **session report** combining UI, API, checkpoints, MCP errors

These are nice-to-haves; they are not blockers for starting analysis today.

---

## Key file index

| Area | Paths |
|------|-------|
| Persistence | `src/core/task-persistence/*`, `src/utils/storage.ts`, `src/shared/globalFileNames.ts` |
| Task runtime | `src/core/task/Task.ts`, `src/core/assistant-message/presentAssistantMessage.ts` |
| Message types | `packages/types/src/message.ts`, `packages/types/src/history.ts` |
| Export | `src/integrations/misc/export-markdown.ts`, `webview-ui/.../TaskActions.tsx` |
| Diagnostics | `src/core/webview/diagnosticsHandler.ts` |
| Telemetry | `packages/telemetry/*`, `packages/types/src/telemetry.ts` |
| Sessions | `src/shared/kilocode/cli-sessions/**` |
| Logging | `src/utils/outputChannelLogger.ts`, `src/utils/networkProxy.ts` |
| MCP | `src/services/mcp/McpHub.ts`, `src/core/tools/UseMcpToolTool.ts` |
| Handler hub | `src/core/webview/webviewMessageHandler.ts` |

---

## Bottom line

You do not need new plugin features to start observing agentic sessions. The richest local material is already on disk:

1. **`api_conversation_history.json`** — tool/agent loop (primary)
2. **`ui_messages.json`** — approvals, MCP/command presentation, metrics (secondary)
3. **OpenAI/local proxy log** — raw LLM wire traffic (complements 1)

Together these cover prompt construction, tool calls/results, and UI-side failures — enough to back-analyze why sessions sometimes miss expected outcomes.
