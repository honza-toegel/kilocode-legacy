# Extending Kilo Code for Code Discovery

This document describes ways to extend Kilo Code without modifying its core agent code, with emphasis on Java, Maven, Spring Boot, and IntelliJ IDEA.

The most useful extension point is MCP. In IntelliJ IDEA 2025.2 and later, JetBrains' bundled MCP Server can expose IDE-indexed symbol search, dependency information, inspections, builds, and other IDE operations directly to Kilo. Rules and custom instructions should then teach the model when to prefer those tools over Kilo's workspace-only searches.

> Scope note: Kilo details below refer to this legacy extension repository. JetBrains MCP capabilities refer to the IntelliJ IDEA documentation available in July 2026. Product surfaces and exposed tool names can change.

## 1. Current code-discovery model

Kilo normally discovers code through a combination of:

1. A recursive workspace file listing included with the first task, capped by `maxWorkspaceFiles` (default 200).
2. `codebase_search`, when Kilo code indexing is enabled and ready.
3. `search_files`, implemented with bundled ripgrep.
4. `list_files` and `read_file`, including explicit line ranges.
5. `execute_command`, when the active mode permits commands.
6. MCP tools and resources exposed by configured servers.

The model decides which tool to call. There is no fixed exploration phase and no configuration that means "run exactly N discovery steps before editing."

### Built-in strengths

- Fast exact-text and regex searches.
- Optional semantic search over workspace files.
- Ranged file reads after a search result.
- Works in both the VS Code extension and Kilo's JetBrains host.
- Shell access allows Maven, JDK, Git, and project-specific utilities to contribute evidence.

### Important limitations

- `search_files` is text search. It does not resolve Java overloads, inheritance, generated members, dependency classes, Spring bean wiring, or dynamic dispatch.
- Kilo's semantic index is based on workspace content, not IntelliJ's PSI/indexes or Maven classpath model.
- `pom.xml` is readable, but Kilo does not independently resolve it into a searchable Java type graph.
- IntelliJ External Libraries, attached source JARs, SDK classes, and library roots are not automatically part of Kilo's workspace search.
- The JetBrains host normally presents `project.basePath` as Kilo's workspace, rather than every IntelliJ content/library root.
- Search results do not automatically trigger a centered read around every hit. The model must request the relevant line range.
- `codebase_search` has a strong built-in instruction to run first for unexplored areas when indexing is ready. Without an explicit rule, this can make it win over a more precise Java MCP tool.
- Kilo cannot replace the implementation of `search_files` through configuration. A smarter discovery engine must be offered as another tool and selected by the model.

## 2. Extension options without changing Kilo core

| Mechanism | Best use | Model visibility | Main limitation |
|---|---|---|---|
| `AGENTS.md` / `.kilocode/rules/` | Repository policy and tool-routing instructions | Prompt text | Guidance, not an enforced tool hook |
| Mode-specific rules in `.kilocode/rules-{mode}/` | Exploration policy for Architect/Ask/custom modes | Prompt text for that mode | Applies only in that mode |
| Custom modes (`.kilocodemodes`) | Dedicated Java investigation mode with selected tool groups | Mode role + allowed tools | Soft policy unless groups remove tools |
| User workflows in `.kilocode/workflows/` | User-typed `/…` investigation recipes | Injected when the user invokes them | Not a new semantic tool |
| Agent commands in `.kilocode/commands/` | Repeatable prompts via `run_slash_command` | Available when that experiment is enabled | Experimental agent slash-command path |
| Skills in `.kilocode/skills/` | On-demand discovery playbooks | Description metadata; agent reads `SKILL.md` | Soft discovery, not a typed tool |
| `execute_command` | Existing Java/Maven CLI utilities | Generic shell tool | Model must construct and parse commands |
| MCP server | Typed PSI/LSP/Maven tools | First-class schema-described tools | Requires a server and careful tool descriptions |
| Experimental custom tools | Lightweight TypeScript/JavaScript wrappers | Native tools | Experimental and disabled by default |
| Generated dependency catalog | Searchable dependency API signatures in-workspace | Existing Kilo search tools | Snapshot rather than live PSI/source semantics |
| Browser / URL fetching | Documentation and web application inspection | Browser tools or URL context | Not Java project intelligence |

MCP is normally preferable to a raw CLI because each operation has a name, description, JSON input schema, and structured result. This gives the model a much clearer choice than the generic `execute_command` tool.

## 3. Native MCP support in Kilo

Kilo uses the official Model Context Protocol SDK and supports:

- `stdio`: starts a local process and communicates over standard input/output.
- `sse`: connects to a Server-Sent Events endpoint. Still supported in this codebase; prefer streamable HTTP for new setups.
- `streamable-http`: connects using the current streamable HTTP MCP transport.

Server configuration supports:

- `command`, `args`, `cwd`, and `env` for stdio.
- `url`, `headers`, and optional OAuth settings for HTTP transports.
- `timeout` from 1 to 3600 seconds, default 60.
- `alwaysAllow` for selected tools.
- `disabledTools` to keep irrelevant or dangerous tools out of the model's tool set.
- `watchPaths` to restart a local server after selected files change.
- Per-server disablement and global MCP disablement.

Project configuration is normally stored in:

```text
.kilocode/mcp.json
```

Kilo also checks `.cursor/mcp.json` and a root-level `.mcp.json` when the Kilo project file is absent. Global servers can be configured through Kilo's MCP settings UI.

The active mode must include the `mcp` tool group. Kilo's built-in Code, Architect, Ask, and Debug modes include it; a custom mode can omit it.

### How MCP tools are shown to the model

The exact presentation depends on the model/provider tool protocol:

- With native function calling, every enabled MCP tool is added to the same API `tools` array as `search_files`. Its MCP description and input schema become its function description and parameters. This is the closest to "the same way as `search_files`."
- With Kilo's XML protocol, MCP tools are listed in the `MCP SERVERS` prompt section and invoked through the generic `use_mcp_tool` wrapper. They remain available, but have less prominent presentation than a built-in tool.

Native MCP names are sanitized into a form such as:

```text
mcp--intellij--search_symbol
```

Keep MCP server and tool names short because provider-compatible function names are capped at 64 characters.

The full generated prompt can be inspected in Kilo's Modes screen using **Preview system prompt**. This is the best way to verify which MCP descriptions the selected model sees.

## 4. IntelliJ IDEA's bundled MCP Server

Starting with IntelliJ IDEA 2025.2, JetBrains bundles an MCP Server plugin. It is enabled by default unless the plugin was explicitly disabled.

Setup is under:

```text
Settings | Tools | MCP Server
```

From there:

1. Enable the MCP server.
2. Open **Manual Client Configuration**.
3. Copy the SSE, Stdio, or HTTP Stream configuration.
4. Put the equivalent server entry into Kilo's `.kilocode/mcp.json`.
5. Review **Exposed Tools** and disable operations that Kilo should not call.

Prefer the exact configuration generated by the running IDE. Ports and proxy commands are instance-specific, so examples copied from another machine can be wrong.

### Useful built-in tools for Maven/Spring projects

The official server currently exposes tools including:

- `search_symbol`: PSI/index-backed search for classes, methods, and fields. `include_external=true` extends the search to SDK and library symbols.
- `get_symbol_info`: IntelliJ Quick Documentation-style information for the symbol at a file/line/column.
- `get_project_dependencies`: structured names of project dependencies.
- `get_project_modules`: IntelliJ's module view.
- `get_file_problems`: file errors and warnings from IntelliJ inspections.
- `build_project`: IDE build with compilation diagnostics.
- `search_text`, `search_regex`, and file-search tools using IntelliJ's project model.
- `read_file`, run-configuration, terminal, refactoring, debugger, and other tools when enabled.

For dependency discovery, `search_symbol` with `include_external=true` is particularly important: it can query symbols known to IntelliJ's SDK and library indexes without copying all of `~/.m2` into the workspace.

However, this is not unlimited dependency-source access:

- `get_project_dependencies` reports dependency information; it is not a complete source or API index.
- A library must be resolved and indexed by IntelliJ before PSI-backed lookup can find it.
- The official exposed-tool list currently does not include a general-purpose Java `find_usages` or `type_hierarchy` tool.
- Spring runtime behavior still requires reasoning across annotations, configuration, conditions, proxies, generated code, and sometimes runtime evidence.

Those missing operations can be added by an IntelliJ plugin contributing custom tools to JetBrains' MCP server, described later.

## 5. Configuring IntelliJ MCP in Kilo

### Recommended: streamable HTTP

Copy the HTTP Stream URL from IntelliJ, then adapt it to Kilo's schema:

```json
{
  "mcpServers": {
    "intellij": {
      "type": "streamable-http",
      "url": "<paste the URL from IntelliJ Copy HTTP Stream Config>",
      "timeout": 120,
      "alwaysAllow": [
        "search_symbol",
        "get_symbol_info",
        "get_project_dependencies",
        "get_project_modules",
        "get_file_problems"
      ],
      "disabledTools": [
        "execute_terminal_command",
        "replace_text_in_file",
        "rename_refactoring"
      ]
    }
  }
}
```

This example intentionally permits discovery tools while removing overlapping write and command operations. Adjust the list to the exact tools shown by the installed IDE version.

### Alternative: SSE

```json
{
  "mcpServers": {
    "intellij": {
      "type": "sse",
      "url": "<paste the URL from IntelliJ Copy SSE Config>",
      "timeout": 120
    }
  }
}
```

### Alternative: stdio

Use the command and arguments generated by IntelliJ:

```json
{
  "mcpServers": {
    "intellij": {
      "type": "stdio",
      "command": "<command copied from IntelliJ>",
      "args": ["<first generated argument>", "<second generated argument>"],
      "cwd": "<absolute project root>",
      "timeout": 120
    }
  }
}
```

Do not use the old `@jetbrains/mcp-proxy` examples unless an older IDE requires them. That repository is no longer maintained because its core functionality moved into IntelliJ-based IDEs in 2025.2.

### Security and approvals

There are two distinct approval layers:

1. Kilo can ask before invoking an MCP tool unless it is listed in `alwaysAllow`.
2. IntelliJ can ask before executing commands or run configurations unless JetBrains **Brave Mode** is enabled.

For discovery-only use:

- Expose only read/search/inspection tools in IntelliJ.
- Use Kilo `alwaysAllow` only for those read-only tools.
- Leave IntelliJ Brave Mode disabled.
- Do not expose duplicate edit, terminal, debugger, or database tools unless the workflow needs them.

## 6. Prompt instructions for Java/PSI discovery

An MCP server does not automatically replace Kilo's built-in search strategy. The model chooses tools based on descriptions, instructions, task wording, and previous results.

Place a rule such as the following in:

```text
.kilocode/rules/java-intellij-discovery.md
```

Example:

```md
# Java code discovery with IntelliJ MCP

For Java, Kotlin, Maven, and Spring questions, use IntelliJ MCP as the source of
truth for resolved symbols and IDE project structure.

1. For a named class, method, or field, call IntelliJ `search_symbol` before
   `search_files`. Use `include_external=false` for project code first. Retry
   with `include_external=true` when the declaration may come from the JDK or
   a Maven dependency.
2. After locating a symbol, call `get_symbol_info` at its returned file, line,
   and column to obtain the resolved declaration, signature, and documentation.
3. Use `get_project_modules` and `get_project_dependencies` before inferring
   Maven module or dependency relationships from directory names alone.
4. Use `get_file_problems` or `build_project` to validate Java changes. Do not
   treat ripgrep matches as proof that code resolves or compiles.
5. Use Kilo `codebase_search` for concept-level discovery and `search_files`
   for literals, annotations, configuration keys, XML/YAML properties, comments,
   and generated text.
6. If IntelliJ returns no result, verify that Maven import and IDE indexing are
   complete. Then fall back to workspace search. State when the fallback is
   textual rather than symbol-resolved.
7. For Spring wiring, combine PSI evidence with searches for annotations,
   `@Bean` methods, configuration properties, qualifiers, profiles, and
   conditional annotations. Do not claim runtime bean selection from a single
   text match.
8. Never edit dependency sources or IDE library files.
```

A shorter `AGENTS.md` version:

```md
For Java symbol lookup, prefer IntelliJ MCP `search_symbol` and
`get_symbol_info` over regex. Retry library symbols with
`include_external=true`. Use Kilo search for literals/configuration and use
IntelliJ inspections/builds to validate conclusions.
```

If Kilo codebase indexing is enabled, explicitly preserve the distinction:

- `codebase_search`: "Where is order validation implemented?" or other semantic concepts.
- IntelliJ `search_symbol`: "Where is `OrderValidator#validate` declared?" and dependency/JDK symbol lookup.
- `search_files`: exact annotations, property keys, strings, XML, YAML, or regex patterns.

This avoids instructing the model to use PSI for tasks where text or semantic search is more suitable.

## 7. Adding missing PSI operations

The bundled IntelliJ server supplies useful code intelligence, but not every IDE action is exposed. If general Find Usages, call hierarchy, type hierarchy, Spring bean navigation, or custom architectural queries are required, an IntelliJ plugin can contribute tools to the same server.

This changes the companion IntelliJ plugin, not Kilo itself. The resulting tools are discovered through ordinary MCP and work with Kilo's existing client.

The IntelliJ Platform extension pattern is:

```kotlin
class JavaDiscoveryToolset : McpToolset {
    @McpToolHints(readOnlyHint = TRUE, openWorldHint = FALSE)
    @McpTool
    @McpDescription(
        """
        Finds resolved usages of a Java declaration using IntelliJ PSI indexes.
        Prefer this over text search when overloads, inheritance, or symbol
        identity matter.
        """
    )
    suspend fun java_find_usages(
        @McpDescription("Fully qualified class name") className: String,
        @McpDescription("Optional method name") methodName: String? = null,
    ): JavaUsagesResult {
        val project = currentCoroutineContext().project
        // Resolve the symbol, wait for smart mode, then execute PSI/index
        // reads inside the coroutine-aware IntelliJ readAction { ... }.
        TODO("Return bounded, structured, project-relative usage locations")
    }
}
```

Register the toolset in the plugin:

```xml
<idea-plugin>
    <depends>com.intellij.mcpServer</depends>
    <extensions defaultExtensionNs="com.intellij">
        <mcpServer.mcpToolset
            implementation="com.example.discovery.JavaDiscoveryToolset" />
    </extensions>
</idea-plugin>
```

The plugin build must declare a compile dependency on JetBrains' bundled `com.intellij.mcpServer` plugin. Public methods annotated with `@McpTool` become tools; `@McpDescription` supplies the descriptions the LLM sees, and serializable parameters/results become MCP schemas.

JetBrains' MCP framework supplies project selection as an implicit `projectPath` input and exposes the selected project through the coroutine context. PSI/VFS reads must run in the coroutine-aware IntelliJ `readAction`; tools should wait for smart mode before querying indexes.

Recommended read-only tools:

- `java_find_usages(symbol, scope, includeLibraries)`
- `java_type_hierarchy(className, direction, depth)`
- `java_call_hierarchy(symbol, direction, depth)`
- `spring_find_bean_candidates(type, qualifiers, module)`
- `spring_find_injection_points(type, qualifier, module)`
- `maven_resolve_type(fqcn, includeSources)`

Tool design matters:

- Return project-relative paths, 1-based lines/columns, symbol signatures, and a short code snippet.
- Bound result counts and hierarchy depth.
- Distinguish project, generated, JDK, and external-library results.
- Report dumb/indexing mode explicitly rather than silently returning no matches.
- Keep discovery tools read-only and declare accurate MCP tool hints.
- Use fully qualified names or file/line/column identities to disambiguate overloads.
- Describe when the model should prefer the tool over `search_files`.
- Avoid one giant "query PSI" tool with an unstructured query language.

## 8. Using an intelligent CLI without MCP

An existing Java explorer can be used immediately through `execute_command`:

```md
For Java references, run:

`java-explore usages --project . --symbol '<fully-qualified-symbol>' --json`

Prefer JSON output. Limit results to 100. If the command reports that the IDE
index is unavailable, fall back to IntelliJ MCP and then text search.
```

This can be placed in `.kilocode/rules/` or a custom mode instruction. The command can also be allowlisted using Kilo's allowed-command settings.

Advantages:

- No MCP wrapper is required.
- Existing jdtls, SCIP, OpenRewrite, Maven, or proprietary utilities can be reused.
- Easy to prototype and inspect manually.

Limitations:

- The model sees only generic `execute_command`, not a dedicated `find_usages` schema.
- Shell quoting, executable location, working directory, timeouts, and output parsing are left to the model.
- Rules can recommend the command but cannot force it to run before built-in search.
- Architect mode does not normally include command execution.
- Large console output is more likely to waste context than a bounded MCP response.

For a durable team workflow, wrap the CLI in an MCP stdio server. The server should validate arguments, invoke the CLI, bound its output, and return structured content.

## 9. Experimental Kilo custom tools

This repository also contains an experimental custom-tool registry. When the `customTools` experiment is enabled, Kilo loads `.ts` and `.js` tool definitions from `tools` directories under global and project `.kilocode`/legacy `.roo` configuration roots. TypeScript is compiled dynamically with esbuild.

A tool definition has the general shape:

```ts
import { defineCustomTool, parametersSchema } from "@roo-code/types"
import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

export default defineCustomTool({
  name: "java_symbol_lookup",
  description:
    "Resolve a Java symbol with the local java-explore CLI. Prefer this over regex when symbol identity matters.",
  parameters: parametersSchema.object({
    symbol: parametersSchema.string().describe("Fully qualified Java symbol"),
  }),
  async execute({ symbol }) {
    const { stdout } = await execFileAsync(
      "java-explore",
      ["symbol", "--json", "--limit", "100", symbol],
      { cwd: process.cwd(), timeout: 60_000, maxBuffer: 2 * 1024 * 1024 },
    )
    return stdout
  },
})
```

This mechanism does not require modifying Kilo core, but it is less suitable for a shared Java integration than MCP:

- The experiment defaults to disabled.
- The API and loading behavior are not a stable public integration contract.
- Tool code executes in the extension host's security context.
- MCP is portable to other clients and naturally matches IntelliJ's server.

Use custom tools for local experiments; use MCP for maintained integrations.

## 10. Other useful extensions

### Rules and custom modes

Rules can establish:

- Preferred discovery order.
- Read-only dependency/source directories.
- Required Maven modules and profiles.
- Build/test commands.
- Rules against guessing external APIs.
- A requirement to cite PSI, compilation, or test evidence before conclusions.

A custom mode can include `read`, `browser`, `command`, and `mcp` while omitting edits, creating a Java investigation mode that can inspect code and run diagnostics without changing files.

### Workflows, commands, and skills

Kilo has three related prompt-extension mechanisms:

| Path | Trigger | Notes |
|---|---|---|
| `.kilocode/workflows/` | User types `/name` in chat | Best for human-started investigation recipes |
| `.kilocode/commands/` | Agent `run_slash_command` | Requires the experimental slash-command tool |
| `.kilocode/skills/` | Agent discovers and `read_file`s `SKILL.md` | Good for optional Spring/Maven playbooks |

Useful names for a Maven/Spring repo:

- `/trace-spring-bean`
- `/inspect-maven-dependency`
- `/explain-java-symbol`
- `/check-module-boundary`

These orchestrate existing tools; they do not add new semantic discovery implementations.

Mode-specific rules belong in `.kilocode/rules-architect/` or `.kilocode/rules-ask/` when Architect/Ask should explore differently from Code. Project custom modes live in `.kilocodemodes` and can include `read`, `browser`, `command`, and `mcp` while omitting `edit`.

### Maven dependency API catalog

The repository's `maven-deps-catalog/` toolkit generates compact `javap -public` signatures under `.kilocode/deps-api/`. It is useful when:

- IntelliJ MCP is unavailable.
- A CI/remote Kilo agent is not connected to a running IDE.
- The team wants deterministic, commit-able dependency API snapshots.
- Only public signatures are needed.

It complements IntelliJ MCP:

- IntelliJ MCP gives live IDE project/index knowledge and can include external symbols.
- The catalog gives workspace-searchable, reproducible public signatures.
- Neither alone proves Spring runtime wiring.

### Web browsing

Kilo can:

- Drive Chromium through `browser_action` for interactive pages and local web applications.
- Fetch a user-mentioned URL into markdown context.
- Use web-search/fetch MCP servers when configured.

The built-in browser is not equivalent to a search-engine API. For autonomous research across documentation, configure a dedicated web search/fetch MCP server and add a rule preferring official Spring, Maven, JDK, and library documentation.

## 11. Recommended setup for a Spring Boot Maven repository

1. Open the Maven reactor/Git root in IntelliJ.
2. Finish Maven import and wait for IntelliJ indexing.
3. Enable JetBrains' bundled MCP Server.
4. Expose only the IntelliJ discovery, inspection, and build tools initially.
5. Copy the IDE-generated HTTP Stream configuration into `.kilocode/mcp.json`.
6. Add `.kilocode/rules/java-intellij-discovery.md`.
7. Enable Kilo codebase indexing only if semantic concept search is useful; keep the routing distinction explicit.
8. Retain the generated Maven dependency API catalog for headless/CI use if needed.
9. Add custom PSI MCP tools only after confirming the bundled `search_symbol`, `get_symbol_info`, inspection, and dependency tools do not cover the use case.
10. Test the setup with representative questions:
    - "Find the declaration and callers of this service method."
    - "Which Maven dependency provides this class?"
    - "Which implementation is injected for this interface under the production profile?"
    - "Show the compilation or inspection evidence for this conclusion."

## 12. Practical decision guide

Use Kilo `search_files` when:

- Looking for exact text, annotations, configuration keys, XML/YAML, comments, or literals.

Use Kilo `codebase_search` when:

- Looking for an implementation by behavior or concept without knowing symbol names.

Use IntelliJ MCP when:

- Symbol identity, project modules, dependencies, external libraries, inspections, or compilation matter.

Use a custom PSI MCP tool when:

- General usages, hierarchy, call graph, Spring model navigation, or organization-specific semantics are required and the bundled server lacks the operation.

Use a CLI through `execute_command` when:

- Prototyping or reusing an existing utility.

Use the Maven dependency catalog when:

- The agent must work headlessly or needs deterministic public API signatures inside the workspace.

## References

- Kilo MCP implementation: `src/services/mcp/McpHub.ts`
- Kilo MCP prompt rendering: `src/core/prompts/sections/mcp-servers.ts`
- Kilo native MCP tool conversion: `src/core/prompts/tools/native-tools/mcp_server.ts`
- Built-in search description: `src/core/prompts/tools/native-tools/search_files.ts`
- Codebase search routing instruction: `src/core/prompts/tools/native-tools/codebase_search.ts`
- Experimental custom tools: `packages/core/src/custom-tools/`
- Project/global command loading: `src/services/command/commands.ts`
- Maven dependency catalog: `maven-deps-catalog/README.md`
- JetBrains IntelliJ MCP Server documentation: <https://www.jetbrains.com/help/idea/mcp-server.html>
- JetBrains MCP tool extension reference: <https://github.com/JetBrains/intellij-community/tree/master/plugins/mcp-server>

