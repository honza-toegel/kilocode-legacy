# Maven dependency API catalog

When working with Spring/Java types that come from **Maven dependencies** (interfaces, annotations, Spring APIs, etc.):

1. **Search the catalog first** under `.kilocode/deps-api/` via `codebase_search` or `search_files` before guessing method signatures.
2. Prefer `INDEX.md` and `by-artifact/*/CLASSES.txt` to locate the right type, then `read_file` the matching `*.sig.txt` (use line ranges for large files).
3. **Never invent** public APIs for dependency types. If a type is missing from the catalog, say so and ask the user to regen (`scripts/generate-deps-api.sh`) or broaden `deps-api.config.yml`.
4. **Never edit** `.kilocode/deps-api/` by hand — it is generated output.
5. Project/source code under `src/` always takes priority over catalog stubs when both exist.
