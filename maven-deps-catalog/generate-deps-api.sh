#!/usr/bin/env bash
# generate-deps-api.sh — Build a compact public-API catalog for Maven deps.
# Copy into your Maven project (e.g. scripts/) and run from the reactor root.
#
# Usage:
#   ./scripts/generate-deps-api.sh
#   ./scripts/generate-deps-api.sh -f path/to/pom.xml
#   MODULE=my-app ./scripts/generate-deps-api.sh
#
# Requires: bash, mvn, jar, javap (JDK 17+ via JAVA_HOME), awk, sed.
# Windows: run under Git Bash or WSL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Locate project root (directory with pom.xml)
# ---------------------------------------------------------------------------
POM_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      POM_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

find_pom_root() {
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/pom.xml" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [[ -n "$POM_FILE" ]]; then
  if [[ ! -f "$POM_FILE" ]]; then
    echo "ERROR: pom not found: $POM_FILE" >&2
    exit 1
  fi
  PROJECT_ROOT="$(cd "$(dirname "$POM_FILE")" && pwd)"
  POM_FILE="$PROJECT_ROOT/$(basename "$POM_FILE")"
else
  PROJECT_ROOT="$(find_pom_root "$(pwd)" || true)"
  if [[ -z "$PROJECT_ROOT" ]]; then
    # Also try script-relative: scripts/../pom.xml or toolkit still in maven-deps-catalog
    if [[ -f "$SCRIPT_DIR/../pom.xml" ]]; then
      PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    else
      echo "ERROR: No pom.xml found. Run from a Maven project root or pass -f path/to/pom.xml" >&2
      exit 1
    fi
  fi
  POM_FILE="$PROJECT_ROOT/pom.xml"
fi

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    echo "  Install Maven / JDK 17+ and ensure PATH (or JAVA_HOME/bin) includes it." >&2
    exit 1
  fi
}

need_cmd mvn
need_cmd jar
need_cmd javap
need_cmd awk
need_cmd sed

JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
if [[ -n "${JAVA_HOME:-}" ]]; then
  if [[ ! -x "${JAVA_HOME}/bin/javap" ]]; then
    echo "ERROR: JAVA_HOME is set but javap not found at ${JAVA_HOME}/bin/javap" >&2
    exit 1
  fi
  PATH="${JAVA_HOME}/bin:${PATH}"
fi

# Soft JDK version hint
JAVA_VER="$(javap -version 2>&1 | head -1 || true)"
echo "==> Using javap: ${JAVA_VER:-unknown} (need JDK 17+ recommended)"

# ---------------------------------------------------------------------------
# Config (simple YAML subset)
# ---------------------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/.kilocode/deps-api.config.yml}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  # Fallback: example next to script (toolkit layout) or scripts/../
  for candidate in \
    "$PROJECT_ROOT/deps-api.config.yml.example" \
    "$SCRIPT_DIR/deps-api.config.yml.example" \
    "$SCRIPT_DIR/../deps-api.config.yml.example"; do
    if [[ -f "$candidate" ]]; then
      echo "WARN: no $CONFIG_FILE — using defaults from example at $candidate" >&2
      CONFIG_FILE="$candidate"
      break
    fi
  done
fi

# Defaults
DIRECT_ONLY=true
MAX_CLASSES=400
OUTPUT_DIR=".kilocode/deps-api"
declare -a MODULES=()
declare -a INCLUDE_ARTIFACTS=()
declare -a EXCLUDE_ARTIFACTS=()

yaml_get_scalar() {
  # $1=file $2=key  → prints value (bool/int/string) or empty
  # Uses BSD/macOS-compatible awk (avoid '#' inside character classes).
  local file="$1" key="$2"
  awk -v key="$key" '
    /^[ \t]*#/ { next }
    $0 ~ "^" key ":" {
      sub("^[^:]+:[ \t]*", "")
      gsub(/[ \t]+#.*$/, "")
      gsub(/^[\042\047]|[\042\047]$/, "")
      print
      exit
    }
  ' "$file"
}

yaml_get_list() {
  # $1=file $2=key  → prints one item per line (from "key: []" or block list)
  # Avoid '#' inside awk regex character classes (breaks macOS/BSD awk).
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { inlist=0 }
    /^[ \t]*#/ { next }
    $0 ~ "^" key ":[ \t]*\\[\\][ \t]*$" { exit }
    $0 ~ "^" key ":[ \t]*\\[" {
      line=$0
      sub("^[^:]+:[ \t]*\\[", "", line)
      sub("\\].*$", "", line)
      n=split(line, a, ",")
      for (i=1;i<=n;i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", a[i])
        gsub(/^[\042\047]|[\042\047]$/, "", a[i])
        if (a[i] != "") print a[i]
      }
      exit
    }
    $0 ~ "^" key ":[ \t]*$" { inlist=1; next }
    inlist {
      first = substr($0, 1, 1)
      if (first != " " && first != "\t" && first != "#") { exit }
      if ($0 ~ /^[ \t]*-[ \t]*/) {
        sub(/^[ \t]*-[ \t]*/, "")
        gsub(/[ \t]+#.*$/, "")
        gsub(/^[\042\047]|[\042\047]$/, "")
        if ($0 != "") print
      }
    }
  ' "$file"
}

if [[ -f "$CONFIG_FILE" ]]; then
  v="$(yaml_get_scalar "$CONFIG_FILE" "directOnly")"
  [[ -n "$v" ]] && DIRECT_ONLY="$v"
  v="$(yaml_get_scalar "$CONFIG_FILE" "maxClassesPerArtifact")"
  [[ -n "$v" ]] && MAX_CLASSES="$v"
  v="$(yaml_get_scalar "$CONFIG_FILE" "outputDir")"
  [[ -n "$v" ]] && OUTPUT_DIR="$v"

  while IFS= read -r line; do
    [[ -n "$line" ]] && MODULES+=("$line")
  done < <(yaml_get_list "$CONFIG_FILE" "modules")

  while IFS= read -r line; do
    [[ -n "$line" ]] && INCLUDE_ARTIFACTS+=("$line")
  done < <(yaml_get_list "$CONFIG_FILE" "includeArtifacts")

  while IFS= read -r line; do
    [[ -n "$line" ]] && EXCLUDE_ARTIFACTS+=("$line")
  done < <(yaml_get_list "$CONFIG_FILE" "excludeArtifacts")
fi

# MODULE env overrides / appends a single module filter
if [[ -n "${MODULE:-}" ]]; then
  MODULES=("$MODULE")
fi

OUTPUT_ABS="$PROJECT_ROOT/$OUTPUT_DIR"
BY_ARTIFACT="$OUTPUT_ABS/by-artifact"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deps-api.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "==> Project root: $PROJECT_ROOT"
echo "==> Config:       ${CONFIG_FILE:-<defaults>}"
echo "==> Output:       $OUTPUT_ABS"
echo "==> directOnly:   $DIRECT_ONLY  maxClassesPerArtifact: $MAX_CLASSES"

# ---------------------------------------------------------------------------
# Pattern matching for include/exclude (groupId:artifactId or artifactId or prefix*)
# ---------------------------------------------------------------------------
pattern_matches() {
  # $1=groupId $2=artifactId $3=pattern
  local g="$1" a="$2" p="$3"
  local ga="${g}:${a}"
  case "$p" in
    *\*)
      local prefix="${p%\*}"
      [[ "$ga" == "$prefix"* || "$a" == "$prefix"* || "$g" == "$prefix"* ]] && return 0
      ;;
    *:*)
      [[ "$ga" == "$p" ]] && return 0
      ;;
    *)
      [[ "$a" == "$p" || "$ga" == "$p" ]] && return 0
      ;;
  esac
  return 1
}

artifact_allowed() {
  local g="$1" a="$2"
  local i p
  if [[ ${#INCLUDE_ARTIFACTS[@]} -gt 0 ]]; then
    local ok=0
    for p in "${INCLUDE_ARTIFACTS[@]}"; do
      if pattern_matches "$g" "$a" "$p"; then ok=1; break; fi
    done
    [[ $ok -eq 1 ]] || return 1
  fi
  for p in "${EXCLUDE_ARTIFACTS[@]}"; do
    if pattern_matches "$g" "$a" "$p"; then return 1; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Resolve module list
# ---------------------------------------------------------------------------
declare -a RESOLVE_MODULES=()
if [[ ${#MODULES[@]} -gt 0 ]]; then
  RESOLVE_MODULES=("${MODULES[@]}")
else
  # Auto-discover <module> children from the reactor pom; else just "."
  while IFS= read -r m; do
    [[ -n "$m" ]] && RESOLVE_MODULES+=("$m")
  done < <(sed -n 's|.*<module>\([^<]*\)</module>.*|\1|p' "$POM_FILE" 2>/dev/null || true)
  if [[ ${#RESOLVE_MODULES[@]} -eq 0 ]]; then
    RESOLVE_MODULES=(".")
  fi
fi

echo "==> Modules: ${RESOLVE_MODULES[*]}"

# ---------------------------------------------------------------------------
# Collect unique artifacts: group|artifact|version|packaging|path|module
# ---------------------------------------------------------------------------
ARTIFACTS_FILE="$TMP_DIR/artifacts.tsv"
: > "$ARTIFACTS_FILE"

resolve_module_deps() {
  local module="$1"
  local out="$TMP_DIR/deps-${module//\//_}.txt"
  local mvn_args=(-f "$POM_FILE" -B -q)
  if [[ "$module" != "." ]]; then
    mvn_args+=(-pl "$module" -am)
  fi

  local exclude_flag=()
  case "$DIRECT_ONLY" in
    true|True|TRUE|yes|Yes|1) exclude_flag=(-DexcludeTransitive=true) ;;
  esac

  echo "    resolving dependencies for module: $module"
  # shellcheck disable=SC2086
  if ! mvn "${mvn_args[@]}" dependency:list \
    ${exclude_flag[@]+"${exclude_flag[@]}"} \
    -DoutputAbsoluteArtifactFilename=true \
    -DoutputFile="$out" >/dev/null 2>"$TMP_DIR/mvn-err-${module//\//_}.log"; then
    echo "ERROR: mvn dependency:list failed for module '$module'." >&2
    echo "---- mvn stderr (tail) ----" >&2
    tail -n 40 "$TMP_DIR/mvn-err-${module//\//_}.log" >&2 || true
    exit 1
  fi

  # Lines look like:
  #   group:artifact:jar:version:scope:/abs/path.jar
  #   group:artifact:jar:classifier:version:scope:/abs/path.jar
  awk -v mod="$module" '
    /^[ \t]*[^#[ \t].*:.*:.*:/ {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      n=split(line, p, ":")
      if (n < 6) next
      path=p[n]
      if (path !~ /\.jar$/) next
      if (n == 6) {
        # g:a:type:ver:scope:path
        g=p[1]; a=p[2]; type=p[3]; ver=p[4]; scope=p[5]
      } else if (n == 7) {
        # g:a:type:classifier:ver:scope:path
        g=p[1]; a=p[2]; type=p[3]; ver=p[5]; scope=p[6]
      } else {
        next
      }
      if (type != "jar") next
      if (scope == "test") next
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", g, a, ver, type, path, mod
    }
  ' "$out" >> "$ARTIFACTS_FILE"
}

for mod in "${RESOLVE_MODULES[@]}"; do
  resolve_module_deps "$mod"
done

# Deduplicate by group:artifact:version (keep first path)
UNIQUE_FILE="$TMP_DIR/unique.tsv"
awk -F'\t' '!seen[$1 FS $2 FS $3]++' "$ARTIFACTS_FILE" > "$UNIQUE_FILE"

TOTAL_RAW="$(wc -l < "$UNIQUE_FILE" | tr -d ' ')"
echo "==> Resolved ${TOTAL_RAW} unique artifact(s) before include/exclude"

# ---------------------------------------------------------------------------
# Wipe / rebuild by-artifact (leave rules/config alone)
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_ABS"
rm -rf "$BY_ARTIFACT"
mkdir -p "$BY_ARTIFACT"

MANIFEST_ITEMS="$TMP_DIR/manifest-items.jsonl"
: > "$MANIFEST_ITEMS"
INDEX_BODY="$TMP_DIR/index-body.md"
: > "$INDEX_BODY"

json_escape() {
  # minimal JSON string escape
  printf '%s' "$1" | awk '
    BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      gsub(/\n/, "\\n")
      print
    }'
}

process_jar() {
  local g="$1" a="$2" ver="$3" jar_path="$4" mod="$5"
  local folder="${g}_${a}_${ver}"
  # sanitize folder name
  folder="$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9._-]/_/g')"
  local dest="$BY_ARTIFACT/$folder"
  mkdir -p "$dest"

  if [[ ! -f "$jar_path" ]]; then
    echo "WARN: JAR not found, skipping ${g}:${a}:${ver} ($jar_path)" >&2
    return 0
  fi

  local classes_file="$dest/CLASSES.txt"
  local class_list="$TMP_DIR/classes-${folder}.txt"

  # Public top-level classes only (skip inner $ classes, package-info, module-info)
  jar tf "$jar_path" 2>/dev/null \
    | grep '\.class$' \
    | grep -v '\$' \
    | grep -v 'package-info\.class$' \
    | grep -v 'module-info\.class$' \
    | sed 's/\.class$//' \
    | tr '/' '.' \
    | sort -u > "$class_list" || true

  local count
  count="$(wc -l < "$class_list" | tr -d ' ')"
  local extracted=0
  local truncated=0

  {
    echo "# ${g}:${a}:${ver}"
    echo "# source module: ${mod}"
    echo "# jar: ${jar_path}"
    echo "# total_classes: ${count}"
    echo
  } > "$classes_file"

  local classpath="$jar_path"
  # Include the JAR itself; javap -classpath is enough for public sigs of that artifact

  while IFS= read -r fqcn; do
    [[ -z "$fqcn" ]] && continue
    if [[ "$extracted" -ge "$MAX_CLASSES" ]]; then
      truncated=1
      break
    fi
    echo "$fqcn" >> "$classes_file"

    # Mirror package path under dest
    local rel_path
    rel_path="$(printf '%s' "$fqcn" | tr '.' '/')".sig.txt
    local sig_file="$dest/$rel_path"
    mkdir -p "$(dirname "$sig_file")"

    {
      echo "# ${fqcn}"
      echo "# from ${g}:${a}:${ver}"
      echo
      # -public: public members only; ignore javap failures for odd classes
      if ! javap -public -classpath "$classpath" "$fqcn" >"$sig_file.tmp" 2>/dev/null; then
        echo "// javap failed for ${fqcn}" >"$sig_file.tmp"
      fi
      cat "$sig_file.tmp"
      rm -f "$sig_file.tmp"
    } > "$sig_file"

    extracted=$((extracted + 1))
  done < "$class_list"

  if [[ "$truncated" -eq 1 ]]; then
    echo "# truncated: only first ${MAX_CLASSES} of ${count} classes extracted" >> "$classes_file"
  fi

  echo "- **${g}:${a}:${ver}** → \`by-artifact/${folder}/\` (${extracted} classes$([ "$truncated" -eq 1 ] && echo ", truncated"))" >> "$INDEX_BODY"

  local g_esc a_esc ver_esc folder_esc jar_esc
  g_esc="$(json_escape "$g")"
  a_esc="$(json_escape "$a")"
  ver_esc="$(json_escape "$ver")"
  folder_esc="$(json_escape "$folder")"
  jar_esc="$(json_escape "$jar_path")"
  printf '{"groupId":"%s","artifactId":"%s","version":"%s","folder":"%s","jar":"%s","classes":%s,"extracted":%s,"truncated":%s,"module":"%s"}\n' \
    "$g_esc" "$a_esc" "$ver_esc" "$folder_esc" "$jar_esc" "$count" "$extracted" "$truncated" "$(json_escape "$mod")" \
    >> "$MANIFEST_ITEMS"

  echo "    catalogued ${g}:${a}:${ver} (${extracted}/${count})"
}

SELECTED=0
while IFS=$'\t' read -r g a ver type jar_path mod; do
  [[ -z "$g" ]] && continue
  if ! artifact_allowed "$g" "$a"; then
    continue
  fi
  SELECTED=$((SELECTED + 1))
  process_jar "$g" "$a" "$ver" "$jar_path" "$mod"
done < "$UNIQUE_FILE"

echo "==> Catalogued ${SELECTED} artifact(s)"

# ---------------------------------------------------------------------------
# INDEX.md + MANIFEST.json
# ---------------------------------------------------------------------------
{
  echo "# Maven dependency API catalog"
  echo
  echo "Generated by \`generate-deps-api.sh\` for agent lookup of public dependency signatures."
  echo
  echo "- Project: \`${PROJECT_ROOT}\`"
  echo "- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "- directOnly: \`${DIRECT_ONLY}\`"
  echo "- maxClassesPerArtifact: \`${MAX_CLASSES}\`"
  echo "- Artifacts: ${SELECTED}"
  echo
  echo "## How to use"
  echo
  echo "1. Search this tree (\`codebase_search\` / \`search_files\`) for a type or method name."
  echo "2. Open \`by-artifact/*/CLASSES.txt\` to find the FQCN."
  echo "3. Read the matching \`*.sig.txt\` (public \`javap\` output)."
  echo
  echo "## Artifacts"
  echo
  if [[ ! -s "$INDEX_BODY" ]]; then
    echo "_No artifacts selected. Check include/exclude filters and that dependencies resolved._"
  else
    cat "$INDEX_BODY"
  fi
} > "$OUTPUT_ABS/INDEX.md"

{
  echo "{"
  echo "  \"generatedAt\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
  echo "  \"projectRoot\": \"$(json_escape "$PROJECT_ROOT")\","
  echo "  \"directOnly\": $([[ "$DIRECT_ONLY" == "true" || "$DIRECT_ONLY" == "True" ]] && echo true || echo false),"
  echo "  \"maxClassesPerArtifact\": ${MAX_CLASSES},"
  echo "  \"artifactCount\": ${SELECTED},"
  echo "  \"artifacts\": ["
  if [[ -s "$MANIFEST_ITEMS" ]]; then
    awk 'NR>1{print prev ","} {prev=$0} END{if(NR>0) print prev}' "$MANIFEST_ITEMS" | sed 's/^/    /'
  fi
  echo "  ]"
  echo "}"
} > "$OUTPUT_ABS/MANIFEST.json"

echo
echo "Done."
echo "  INDEX:    $OUTPUT_ABS/INDEX.md"
echo "  MANIFEST: $OUTPUT_ABS/MANIFEST.json"
echo "  Classes:  $BY_ARTIFACT/"
echo
echo "Tip: enable Kilo Codebase Indexing so codebase_search can find .sig.txt files."
echo "     Do not add .kilocode/deps-api/ to .kilocodeignore."
