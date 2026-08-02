# Kilo Code vs Cursor — Agent Loop, Exploration, External Sources

Comparison focused on the **agentic coding loop**, **codebase exploration**, **external/Maven sources**, and related controls that matter for **Spring Boot Maven** projects. Based on how Kilo Code (legacy extension + JetBrains plugin in this repo) works, and how Cursor’s coding agent typically behaves in practice.

| Audience | IntelliJ / VS Code users evaluating Kilo vs Cursor for Java/Spring Boot Maven repos |
| Scope note | Product surfaces evolve; treat Cursor details as behavioral patterns of the current agent IDE, and Kilo details as implemented in this codebase. |

---

## 1. Agentic loop (how a new task runs)

Both are **ReAct-style** agents: there is **no** separate “do I need tools?” API call. The model gets the task + tool definitions, emits tool calls (or text), receives results, and continues until completion / abort / safety limits.

| Step | Kilo Code | Cursor |
|------|-----------|--------|
| Task intake | User message → `<task>` wrapping → `initiateTaskLoop` / recursive LLM requests | User message starts Agent (or Plan/Ask/Debug) turn with rules, open files, and context |
| First-turn free context | Env details + **recursive workspace file tree** (`maxWorkspaceFiles`, default **200**; `0` disables) | Open/recent files, selections, rules (`AGENTS.md`, `.cursor/rules`), often git/editor context; **no equivalent of Kilo’s fixed first-turn recursive tree capped at 200** (exploration is mostly tool-driven from the start) |
| Tool protocol | XML tool tags and/or **native** function calling | Native tool calls (IDE-integrated tool host) |
| Loop end | `attempt_completion`, user abort, mistake limit, auto-approve request/cost ceilings | Agent finishes, user stop, or mode/policy constraints |
| Parallel help | Modes + optional Agent Manager / `@kilocode/agent-runtime` forks (VS Code-oriented) | **Subagents** (e.g. explore / shell / general) can run parallel investigations |

**Verdict:** Same fundamental loop. Kilo injects an explicit truncated file listing on turn one; Cursor leans harder on indexer + ad-hoc tools + subagents, and on files you already have open.

---

## 2. Modes (explore vs act)

| Concern | Kilo Code | Cursor |
|---------|-----------|--------|
| Default implementation | **code** — full read + edit + command; explore depth is model-chosen | **Agent** — full tools; explore depth is model-chosen |
| Plan / gather first | **architect** — gather context, plan/todos; edits limited to markdown; **no** `execute_command` | **Plan** — design before implement; read-oriented collaboration |
| Q&A only | **ask** — read (+ browser/MCP), no edits | **Ask** — read-only answers |
| Debug bias | **debug** — hypothesize / instrument before fix | **Debug** — evidence-led troubleshooting |
| Soft policy | Mode `customInstructions`, `.kilocodemodes`, `.kilocode/system-prompt-<mode>` | Rules, user rules, mode switch; custom skills/hooks |

**Neither** hard-codes “explore N steps then act.” Closest knobs are mode prompts, auto-approve/request caps (Kilo), and user rules.

---

## 3. Code exploration tools

### 3.1 Tool map

| Capability | Kilo Code | Cursor (typical) |
|------------|-----------|------------------|
| Semantic / meaning search | `codebase_search` (only if indexing enabled + ready); prompt strongly nudges **use first** for new areas | Built-in codebase / semantic search (indexer-backed); explore subagents also search broadly |
| Regex / text search | `search_files` → **bundled ripgrep** (`rg` / `rg.exe`) | `Grep` → ripgrep-style search (with limits, filters, context) |
| List / glob | `list_files` (hard ~**200** per call) | `Glob` + directory listing via shell when needed |
| Read file | `read_file` | `Read` |
| Shell | `execute_command` (cwd = workspace; execa default or IDE terminal) | `Shell` (project cwd; rich terminal bridge) |
| Edits | `apply_diff` / `write_to_file` / `edit_file` / … | Apply patches / write / search-replace style tools |
| Extra | MCP tools, browser, modes (`switch_mode`, `new_task`) | MCP, browser/web fetch, Task/subagents, canvas, etc. |

### 3.2 Ripgrep / Windows / IntelliJ

| | Kilo Code | Cursor |
|--|-----------|--------|
| Binary | **Bundled** `@vscode/ripgrep` — does **not** require system `rg` on PATH | Bundled / host-provided ripgrep; not dependent on user installing `rg` |
| Windows | `rg.exe` supported | Supported |
| JetBrains | Same extension host inside IntelliJ plugin → same bundled rg | Cursor is its **own** IDE (VS Code fork); **not** an IntelliJ plugin. For JetBrains-native workflow, Kilo is the in-IDE option |

### 3.3 What grep returns vs what `read_file` / `Read` loads

| | Kilo Code | Cursor |
|--|-----------|--------|
| Search output | Matching lines + ~**1** line context; cap ~**300** matches; lines truncated ~**500** chars | Matching lines + optional context (`-A/-B/-C`); result caps / head limits |
| Full file after hit? | **Not automatic.** Default `read_file` = **from file start**, first `maxReadFileLine` lines (default **500**) | **Not automatic.** Model chooses `Read` with optional **offset/limit** (line window) |
| Positioned read? | **Yes**, via `line_range` / `line_ranges` (`start-end`, 1-based), when partial reads are enabled (`maxReadFileLine !== -1`) | **Yes**, via Read `offset` + `limit` (window around a known line) |
| Center on match? | **No auto ±N.** Model must pick ranges from grep line numbers | **No auto ±N.** Same — model must choose a window |

So for both: grep → then a good model requests a **range around the hit**; a weak turn may re-read only the head of the file and miss the relevant Spring service middle of a large class.

---

## 4. Code indexing (semantic search)

| | Kilo Code | Cursor |
|--|-----------|--------|
| IDE coverage | VS Code extension **and** JetBrains plugin (same Node indexing service) | Cursor IDE only |
| Default | **Off** until enabled | Product-managed index (availability depends on privacy / settings) |
| Enable | Chat DB / indexing badge or settings: embedder (OpenAI / Gemini / Ollama) + **Qdrant** | Cursor settings / privacy mode (local vs cloud indexing as product allows) |
| Scope | **Workspace folder(s) only** | **Workspace / indexed project roots** (not arbitrary `~/.m2`) |
| JetBrains workspace | Single folder = IntelliJ `project.basePath` (not full ModuleRootManager / Maven library roots) | N/A (not in IntelliJ) |
| Maven / JARs | **Not** resolved; no automatic source-jar indexing | **Not** resolved as Maven classpath; sources only if present under workspace (or explicitly opened/attached as folders) |
| Languages | Tree-sitter includes **Java / Kotlin** among others | Broad language support including Java |

**Verdict:** Both stay inside the project tree for indexing. Neither “understands” the Maven dependency graph as an index source unless those sources live in-workspace.

---

## 5. External sources, Maven, Spring Boot

| Topic | Kilo Code | Cursor |
|-------|-----------|--------|
| `pom.xml` | Readable via tools; **not** treated as a dependency indexer | Same — readable, not a classpath indexer |
| `~/.m2` / dependency JARs | Out of scope unless under workspace | Out of scope unless under workspace / added folder |
| Attached IJ library sources | **Not** wired into agent workspace | N/A (no IntelliJ content roots) |
| IntelliJ scratches outside project | Not in cwd tree | If outside workspace folder, generally not indexed |
| Ignored noise | `.kilocodeignore`, gitignore, `DIRS_TO_IGNORE` (`node_modules`, `vendor`, `target/dependency`, …) | `.cursorignore`, `.gitignore`, product ignores |
| Multi-module Maven | Best if **repo root** is the opened workspace so all modules share one tree | Same — open monorepo root as workspace |

### Practical pattern (both tools) for “aware of deps, not confused”

For Spring Boot when you need library **source**:

1. Extract or vendor only the needed artifacts under something like `third-party-src/<artifactId>/…` **inside** the repo (or a dedicated workspace folder).
2. Document in `AGENTS.md` / rules: *project code = `src/…`; `third-party-src/` = read-only reference; never edit.*
3. Optionally ignore write paths / heavy trees via `.kilocodeignore` or `.cursorignore`.
4. Prefer that over dumping all of `~/.m2` into context (noise and confusion).

Kilo-specific: JetBrains currently exposes **one** workspace root (`project.basePath`), so multi-content-root IJ projects still look like a single folder to the agent unless everything lives under that path.

---

## 6. Configuration knobs (exploration & context)

| Knob | Kilo Code | Cursor |
|------|-----------|--------|
| First-turn tree size | `maxWorkspaceFiles` (0–500, default 200) | No direct twin; use rules / @ / indexer |
| Read line cap | `maxReadFileLine` (default 500; `-1` = uncapped subject to token budget) | Read offset/limit chosen per call; large files truncate with notice |
| Partial / ranged reads | `line_range` when partial reads enabled | `offset` / `limit` on Read |
| Exploration “depth” | No dedicated setting; modes + `allowedMaxRequests` / cost + mistake limit | No dedicated setting; modes + rules + subagents |
| Custom policy | `.kilocode/rules/`, `.kilocoderules`, `AGENTS.md`, mode prompts | `.cursor/rules/`, user rules, `AGENTS.md`, skills |
| Auto-approve | Per tool class + max requests/cost; optional yolo | Auto-run / approval settings in product |
| Indexing toggle | Explicit codebase indexing + Qdrant | Cursor privacy / index settings |

---

## 7. Platform fit for Spring Boot teams

| Need | Prefer leaning… |
|------|-----------------|
| Stay inside **IntelliJ IDEA** with agent in a tool window | **Kilo Code** JetBrains plugin |
| Cursor-native UX, multi-root VS Code-style workspace, subagents, product index | **Cursor** |
| Same agent behavior in VS Code *and* IntelliJ | **Kilo** (shared extension) |
| Semantic search without self-hosting Qdrant | **Cursor** (managed) more turnkey; Kilo needs embedder + Qdrant for local index |
| Control first-turn file listing size | **Kilo** (`maxWorkspaceFiles`) |
| Heavy parallel “explore this Maven module” | **Cursor** Task/explore subagents; Kilo can use modes / Agent Manager but JetBrains path is single host |

---

## 8. Side-by-side mental model

```
                    ┌─────────────────────────┐
  User task ───────▶│  LLM (+ mode/rules)     │
                    │  decides tool calls     │
                    └───────────┬─────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
 semantic search          ripgrep search            shell / Maven CLI
 (workspace index)        (bundled rg)              (project cwd)
        │                       │                       │
        └───────────┬───────────┘                       │
                    ▼                                   │
              read ranges around hits                   │
              (explicit line windows) ◀─────────────────┘
                    │
                    ▼
              edit / more tools / complete
```

**Shared for Spring Boot Maven:** agent sees **your workspace**, not IntelliJ’s library table. Dependency source awareness is a **workspace packaging + rules** problem, not something either agent solves via `pom.xml` alone.

---

## 9. Quick checklist for a Spring Boot Maven repo

- [ ] Open the **Maven/Git root** as the workspace (all modules visible).
- [ ] Enable semantic indexing if you want meaning-first find (Kilo: embedder + Qdrant; Cursor: product index).
- [ ] Add `.kilocodeignore` / `.cursorignore` for `target/`, huge generated trees, and any vendored noise you don’t want edited.
- [ ] If agents must read framework sources: vendor under `third-party-src/` + “read-only deps” rules — don’t rely on `~/.m2`.
- [ ] Prefer **architect / Plan** for large unfamiliar modules before **code / Agent** edits.
- [ ] Expect good runs to do: `codebase_search`/`semantic` → `search_files`/`Grep` → **`line_range` / offset Read** around hits — not “grep then always file head.”

---

## 10. Summary

| Dimension | Similar? | Difference that matters |
|-----------|----------|-------------------------|
| Agentic loop | Yes (ReAct) | Kilo’s optional first-turn recursive file list; Cursor’s stronger subagent parallel explore |
| Code exploration tools | Yes (semantic + rg + read + shell) | Naming/APIs; Kilo has stricter per-call list caps and explicit `maxReadFileLine` |
| Grep → read relevance | Same pitfall | Both need **explicit ranged reads**; neither auto-centers on match |
| External Maven sources | Same limitation | Workspace-only unless vendored; Kilo-on-IJ can’t see IJ library roots |
| IntelliJ | — | **Kilo** plugs into IntelliJ; **Cursor** is a separate IDE |
| Indexing setup | Both workspace-bound | Kilo: DIY Qdrant + embedder; Cursor: product-managed |

Both are strong for in-repo Spring Boot work. For **dependency-source-aware** agents, invest in **in-repo (or multi-root) source layout + rules**, not in expecting either product to crawl Maven’s local repository automatically.
