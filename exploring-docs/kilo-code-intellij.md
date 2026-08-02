# Kilo Code with IntelliJ MCP: focused Java analysis tools

This note describes how to expose only a small IntelliJ MCP tool set to Kilo Code, with emphasis on Java, Maven, and Spring Boot dependency awareness.

The main recommendation is:

> Filter tools in IntelliJ, at the MCP server, and use Kilo's MCP settings only as a second safety layer.

Server-side filtering means unwanted tools are not advertised to Kilo at all. This reduces prompt/tool-schema size and gives the model fewer overlapping tools to choose from.

## What the different disable controls do

There are several controls with different scopes:

- **IntelliJ: Enable MCP Server**
  - Disabling this stops IntelliJ's MCP server for every connected client.
  - Kilo cannot use any IntelliJ tool.
- **Kilo: global MCP toggle**
  - Disabling this disconnects every MCP server configured in Kilo, not only IntelliJ.
- **Kilo: toggle on the `intellij` server**
  - Disables only Kilo's connection to that MCP server.
  - It does not change what IntelliJ exposes to other clients.
- **Kilo: toggle beside an individual tool**
  - Adds or removes the exact tool name in the server's `disabledTools` list.
  - Disabled tools are omitted from native function definitions and the XML MCP prompt, and Kilo rejects attempts to call them.
- **Kilo: `alwaysAllow`**
  - Controls approval, not visibility.
  - Adding a tool to `alwaysAllow` does not remove other tools from the model's context.

Kilo currently has no `enabledTools` allow-list and no bulk “disable all tools” action in its MCP tool list. Its configuration has an exact-name `disabledTools` deny-list. Consequently, disabling forty tools in Kilo is possible but cumbersome and not future-proof: a newly added IntelliJ tool is enabled until it is explicitly denied.

## Recommended: filter in IntelliJ

Open:

```text
Settings | Tools | MCP Server | Exposed Tools
```

JetBrains officially documents this as the place to enable or disable exposed tools.

### Category toggles

Recent IntelliJ builds group tools by category. The checkbox in a category header is a three-state checkbox and changes the whole category, so it is not necessary to toggle every row individually.

A practical setup is:

1. Disable all categories.
2. Enable only the individual analysis tools listed below.
3. Apply the settings.
4. Restart or reconnect the IntelliJ MCP server in Kilo so the client obtains the new tool list.

The exact UI varies by IntelliJ and MCP Server plugin version. If the installed version shows only a flat list or does not make bulk selection convenient, use the mask filter below.

### Mask-based allow-list

Current IntelliJ MCP Server sources support ordered, comma-separated masks:

- `-pattern` denies matching tools.
- `+pattern` allows matching tools.
- Entries are evaluated in order; the last matching entry wins.
- Matching is performed against the tool's fully qualified internal name.

Use this allow-list for the focused Java analysis set:

```text
-*,+*.get_project_status,+*.get_project_modules,+*.get_project_dependencies,+*.search_symbol,+*.get_symbol_info,+*.read_file,+*.lint_files,+*.get_file_problems,+*.build_project
```

Starting with `-*` is important. It keeps future IntelliJ tools disabled unless deliberately added to the allow-list.

There are two ways to configure the mask, depending on the IDE build:

1. Open **Help | Find Action | Registry**.
2. Enable:

   ```text
   mcp.server.show.advanced.filter.options.ui
   ```

3. Return to **Settings | Tools | MCP Server | Exposed Tools**.
4. Enter the mask in the advanced tool-filter field and apply it.

If that advanced field is unavailable, set this Registry value directly to the same mask:

```text
mcp.server.tools.filter
```

These are advanced/internal options and can change between IntelliJ releases. If neither registry key exists, update IntelliJ/the bundled MCP Server plugin or use category/individual checkboxes.

After changing the filter, reconnect the MCP client. Existing MCP sessions may retain the tool list that was advertised when the session started.

## Focused Java analysis subset

Enable these tools first:

- `get_project_status`
  - Reports whether indexing and scanning are complete.
  - Prevents misleading empty results or inspection timeouts.
- `get_project_modules`
  - Identifies IntelliJ modules in multi-module Maven projects.
- `get_project_dependencies`
  - Reports dependencies resolved into IntelliJ's project model.
- `search_symbol`
  - Performs semantic symbol search.
  - `include_external=true` includes JDK and dependency/library symbols.
- `get_symbol_info`
  - Returns Quick Documentation-like type, signature, declaration, and documentation information for a symbol at a source position.
- `read_file`
  - Unlike Kilo's workspace reader, IntelliJ's reader can read dependency sources in JAR/JRT paths and decompile class files.
- `lint_files`
  - Preferred in newer IntelliJ builds for inspecting several edited files.
- `get_file_problems`
  - Compatibility/single-file inspection tool; retain it when `lint_files` is unavailable.
- `build_project`
  - Compiles selected files or the project and returns compiler diagnostics.

`lint_files` is newer than the currently documented compatibility tool `get_file_problems`, so the installed IDE may expose only one of them. It is safe for the allow-list mask to mention a tool that the installed version does not provide.

Do not initially expose IntelliJ file search, text search, terminal, file mutation, formatting, or refactoring tools. Kilo already has workspace tools for those operations. Avoiding duplicates makes tool selection clearer.

Keep these families disabled until a task specifically requires them:

- debugger (`xdebug_*`)
- database and SQL tools
- terminal and run-configuration execution
- file creation and replacement
- formatting and rename refactoring
- Inspection KTS and PSI-generation tools
- IntelliJ platform developer-kit analysis
- notebook, VCS, and framework-specific tools

## Kilo-side fallback

If IntelliJ-side filtering cannot be used, edit the Kilo MCP configuration and list every unwanted tool under `disabledTools`:

```json
{
  "mcpServers": {
    "intellij": {
      "type": "streamable-http",
      "url": "<URL copied from IntelliJ>",
      "timeout": 120,
      "disabledTools": [
        "execute_terminal_command",
        "execute_run_configuration",
        "replace_text_in_file",
        "create_new_file",
        "rename_refactoring",
        "reformat_file"
      ]
    }
  }
}
```

This example is illustrative, not a complete complement of the allow-list. Kilo requires exact tool names and does not interpret wildcard entries in `disabledTools`.

Project configuration belongs in:

```text
.kilocode/mcp.json
```

Global MCP configuration is managed by Kilo's MCP settings UI and stored in Kilo's global `mcp_settings.json`.

For a project-specific IntelliJ integration, prefer `.kilocode/mcp.json`. It keeps the connection policy with the Java project and avoids changing unrelated Kilo workspaces.

## Proposed Kilo rule

Save the following as `.kilocode/rules/intellij-java-analysis.md` in a Java/Spring project, or include it in the relevant custom mode instructions:

```md
# IntelliJ-assisted Java analysis

Use Kilo's native workspace tools for ordinary file listing, text search, reading,
and editing. Use the IntelliJ MCP tools when Java project-model, classpath, PSI,
inspection, or compiler knowledge is required.

For Java, Kotlin, Maven, Gradle, or Spring tasks:

1. Before the first IntelliJ inspection, or when results may be stale, call
   `get_project_status`. Do not rely on PSI or inspection results while the IDE
   is still indexing.
2. Use `get_project_modules` when module ownership or the compilation scope is
   unclear. Use `get_project_dependencies` when the resolved classpath matters.
3. Before writing code against an unfamiliar JDK or dependency API, call
   `search_symbol` with `include_external=true`. Verify the selected declaration
   with `get_symbol_info` or IntelliJ `read_file` on the returned library/JAR
   path. Do not invent packages, methods, overloads, annotations, or generic
   signatures from memory.
4. After editing Java or Kotlin files, run `lint_files` on all touched files.
   If `lint_files` is unavailable, use `get_file_problems` per file. Resolve
   error-level diagnostics before completion.
5. After inspections pass, call `build_project` with `filesToRebuild` limited to
   the touched files when supported. Use a wider module/project build only when
   targeted compilation is insufficient or the user requests it.
6. If a diagnostic reports an unresolved symbol, wrong overload, incompatible
   type, or missing annotation member, return to external symbol lookup and
   dependency source reading before changing code again.
7. If IntelliJ is disconnected, the project is not indexed, or dependency
   information is unavailable, state that limitation. Do not claim that the
   Java change compiles without compiler or build evidence.

Do not call IntelliJ terminal, debugger, database, run-configuration, file-write,
formatting, or refactoring tools unless the task explicitly requires them.
```

## Expected agent loop

For a Spring Boot change involving a dependency type, the intended sequence is:

```text
get_project_status
  -> search_symbol(include_external=true)
  -> get_symbol_info or IntelliJ read_file
  -> edit with Kilo tools
  -> lint_files / get_file_problems
  -> build_project
```

This adds dependency and compiler awareness without replacing Kilo's normal workspace exploration tools.

## Sources

- JetBrains IntelliJ IDEA MCP Server documentation:
  <https://www.jetbrains.com/help/idea/mcp-server.html>
- JetBrains AI Assistant MCP documentation:
  <https://www.jetbrains.com/help/ai-assistant/mcp.html>
- IntelliJ Community MCP Server source and contributor documentation:
  <https://github.com/JetBrains/intellij-community/tree/master/plugins/mcp-server>
- Kilo implementation:
  - `src/services/mcp/McpHub.ts`
  - `src/core/prompts/sections/mcp-servers.ts`
  - `src/core/prompts/tools/native-tools/mcp_server.ts`
  - `src/core/tools/UseMcpToolTool.ts`

Research checked on 2026-07-27. JetBrains' MCP tool set and advanced registry options are version-dependent.
