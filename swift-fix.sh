#!/usr/bin/env bash
# =============================================================================
# swift-fix.sh
# =============================================================================

set -euo pipefail

# ╔═════════════════════════════════════════════════════════════════════════════
# ║  CONFIGURATION  —  edit these to match your setup
# ╚═════════════════════════════════════════════════════════════════════════════

# Binaries
# Leave empty ("") to use whatever is on your $PATH (e.g. from brew install)
SWIFTFORMAT_BIN=""                        # e.g. "./tools/swiftformat"
SWIFTLINT_BIN=""                          # e.g. "./tools/swiftlint"

# Config files
# Leave empty ("") to auto-discover by walking up from the repo root
SWIFTFORMAT_CFG=""                        # e.g. "./.swiftformat"
SWIFTLINT_CFG=""                          # e.g. "./.swiftlint.yml"

# ─────────────────────────────────────────────────────────────────────────────

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}[info]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[warn]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[ ok ]${RESET}  $*"; }
err()    { echo -e "${RED}[err ]${RESET}  $*" >&2; }
step()   { echo -e "\n${BOLD}${CYAN}── $* ${RESET}"; }
divider(){ echo -e "${BOLD}${CYAN}────────────────────────────────────────${RESET}"; }

# ─── Parse flags and positional args ─────────────────────────────────────────
DRY_RUN=false
AUTO_FIX=true
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-fix)  AUTO_FIX=false ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PATH ...]

  No PATH      Staged + unstaged Swift files from git diff (current repo)
  DIRECTORY    Staged + unstaged Swift files from git diff in that repo
  FILE(s)      Process exactly those .swift files — no git diff involved

Options:
  --dry-run    Show which files would be processed, make no changes
  --no-fix     Skip all auto-correct steps; report violations only
  -h, --help   Show this help

Tip: edit the CONFIGURATION block at the top of this script to set
     custom binary and config file paths.
EOF
      exit 0 ;;
    --*) err "Unknown option: $arg"; exit 1 ;;
    *)   POSITIONAL+=("$arg") ;;
  esac
done

# ─── Expand ~ in every positional arg ────────────────────────────────────────
expanded_pos=()
for p in "${POSITIONAL[@]+"${POSITIONAL[@]}"}"; do
  expanded_pos+=("${p/#\~/$HOME}")
done

# ─── Dedup helper (bash 3.2 safe — no associative arrays needed) ─────────────
in_array() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ─── Resolve file mode vs repo mode ──────────────────────────────────────────
files=()
MODE=""

if [[ ${#expanded_pos[@]} -eq 0 ]]; then
  MODE="git-diff"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Not inside a git repository. Pass a repo path or specific .swift files."; exit 1; }

elif [[ ${#expanded_pos[@]} -eq 1 && -d "${expanded_pos[0]}" ]]; then
  MODE="git-diff"
  START_DIR="$(cd "${expanded_pos[0]}" 2>/dev/null && pwd)" \
    || { err "Path does not exist: ${expanded_pos[0]}"; exit 1; }
  REPO_ROOT="$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Not a git repository: $START_DIR"; exit 1; }

else
  MODE="explicit-files"
  for p in "${expanded_pos[@]}"; do
    if [[ -d "$p" ]]; then
      err "Cannot mix directory and file arguments. Pass either a repo path OR .swift files."
      exit 1
    fi
    abs="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" \
      || { err "File not found: $p"; exit 1; }
    [[ "$abs" == *.swift ]] || { warn "Skipping non-Swift file: $abs"; continue; }
    [[ -f "$abs" ]]          || { err "File not found: $abs"; exit 1; }
    in_array "$abs" "${files[@]+"${files[@]}"}" || files+=("$abs")
  done
  REPO_ROOT="$(git -C "$(dirname "${files[0]}")" rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Files must be inside a git repository."; exit 1; }
fi

# ─── Collect git-diff files ───────────────────────────────────────────────────
if [[ "$MODE" == "git-diff" ]]; then
  cd "$REPO_ROOT"
  # sort -u deduplicates staged + unstaged output — no associative array needed
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    abs="$REPO_ROOT/$rel"
    [[ -f "$abs" ]] && files+=("$abs")
  done < <(
    {
      git diff          --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
      git diff --cached --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
    } | sort -u
  )
fi

if [[ ${#files[@]} -eq 0 ]]; then
  warn "No Swift files to process — nothing to do."; exit 0
fi

# ─── Resolve configs (user setting → auto-discover) ──────────────────────────
find_config() {
  local filename="$1" dir="$REPO_ROOT"
  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/$filename" ]] && { echo "$dir/$filename"; return; }
    dir="$(dirname "$dir")"
  done
  echo ""
}

# Expand ~ if user set a path in the config block
[[ -n "$SWIFTFORMAT_CFG" ]] && SWIFTFORMAT_CFG="${SWIFTFORMAT_CFG/#\~/$HOME}"
[[ -n "$SWIFTLINT_CFG"   ]] && SWIFTLINT_CFG="${SWIFTLINT_CFG/#\~/$HOME}"
[[ -n "$SWIFTFORMAT_BIN" ]] && SWIFTFORMAT_BIN="${SWIFTFORMAT_BIN/#\~/$HOME}"
[[ -n "$SWIFTLINT_BIN"   ]] && SWIFTLINT_BIN="${SWIFTLINT_BIN/#\~/$HOME}"

SF_CONFIG="${SWIFTFORMAT_CFG:-$(find_config .swiftformat)}"
SL_CONFIG="${SWIFTLINT_CFG:-$(find_config .swiftlint.yml)}"

# ─── Resolve binaries (user setting → PATH) ──────────────────────────────────
if [[ -n "$SWIFTFORMAT_BIN" ]]; then
  [[ -f "$SWIFTFORMAT_BIN" && -x "$SWIFTFORMAT_BIN" ]] \
    || { err "SWIFTFORMAT_BIN not found or not executable: $SWIFTFORMAT_BIN"; exit 1; }
  SF_BIN="$SWIFTFORMAT_BIN"
else
  SF_BIN="$(command -v swiftformat 2>/dev/null)" \
    || { err "swiftformat not found on PATH. Install: brew install swiftformat"; exit 1; }
fi

if [[ -n "$SWIFTLINT_BIN" ]]; then
  [[ -f "$SWIFTLINT_BIN" && -x "$SWIFTLINT_BIN" ]] \
    || { err "SWIFTLINT_BIN not found or not executable: $SWIFTLINT_BIN"; exit 1; }
  SL_BIN="$SWIFTLINT_BIN"
else
  SL_BIN="$(command -v swiftlint 2>/dev/null)" \
    || { err "swiftlint not found on PATH. Install: brew install swiftlint"; exit 1; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_FIXER="$SCRIPT_DIR/swift_custom_fixes.py"

command -v python3 &>/dev/null \
  || { err "python3 not found. Install: brew install python3"; exit 1; }

[[ -f "$CUSTOM_FIXER" ]] \
  || { err "swift_custom_fixes.py not found at $CUSTOM_FIXER"; exit 1; }

# ─── Summary header ──────────────────────────────────────────────────────────
divider
log "Repo           : $REPO_ROOT"
log "Mode           : $( [[ "$MODE" == "git-diff" ]] && echo "git diff (staged + unstaged)" || echo "explicit file(s)" )"
log "swiftformat    : $SF_BIN"
log "swiftlint      : $SL_BIN"
log "swiftformat cfg: ${SF_CONFIG:-<none found>}"
log "swiftlint cfg  : ${SL_CONFIG:-<none found>}"
log "Files (${#files[@]}):"
for f in "${files[@]}"; do echo "     • ${f#"$REPO_ROOT"/}"; done
divider

# ─── Checksum helper ─────────────────────────────────────────────────────────
checksum() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ─── Reusable SwiftFormat runner ─────────────────────────────────────────────
run_swiftformat() {
  local label="$1"
  local sf_args=()
  [[ -n "$SF_CONFIG" ]] && sf_args+=("--config" "$SF_CONFIG")

  if $DRY_RUN; then
    log "[dry-run] $SF_BIN ${sf_args[*]:-<no config>} -- <file> × ${#files[@]}"
    return
  fi

  local changed=0
  for f in "${files[@]}"; do
    local before after
    before="$(checksum "$f")"
    "$SF_BIN" "${sf_args[@]}" "$f" 2>&1 \
      | grep -Ev "^(Running SwiftFormat|No files matched|1 file formatted)" || true
    after="$(checksum "$f")"
    if [[ "$before" != "$after" ]]; then
      log "  formatted → ${f#"$REPO_ROOT"/}"
      (( changed++ )) || true
    fi
  done

  [[ $changed -eq 0 ]] \
    && ok "$label — no changes needed" \
    || ok "$label — $changed file(s) updated"
}

# ─── Reusable SwiftLint fix runner ───────────────────────────────────────────
run_swiftlint_fix() {
  local sl_args=()
  [[ -n "$SL_CONFIG" ]] && sl_args+=("--config" "$SL_CONFIG")

  if $DRY_RUN; then
    log "[dry-run] $SL_BIN --fix ${sl_args[*]:-<no config>} -- <file> × ${#files[@]}"
    return
  fi

  local changed=0
  for f in "${files[@]}"; do
    local before after
    before="$(checksum "$f")"
    "$SL_BIN" --fix "${sl_args[@]}" "$f" 2>&1 \
      | grep -Ev "^(Done linting|Linting ')" || true
    after="$(checksum "$f")"
    if [[ "$before" != "$after" ]]; then
      log "  fixed → ${f#"$REPO_ROOT"/}"
      (( changed++ )) || true
    fi
  done

  [[ $changed -eq 0 ]] \
    && ok "SwiftLint auto-fix — no changes needed" \
    || ok "SwiftLint auto-fix — $changed file(s) updated"
}

# ─── Step 1: Custom Python fixes ─────────────────────────────────────────────
step "1 / 5  Custom fixes"
log "Applies: param expansion · line-length · filter→first · isEmpty · toggle · zero · random · optional binding"

if $DRY_RUN; then
  log "[dry-run] python3 swift_custom_fixes.py <${#files[@]} files>"
elif $AUTO_FIX; then
  fixer_args=()
  [[ -n "$SL_CONFIG" ]] && fixer_args+=("--swiftlint-config"   "$SL_CONFIG")
  [[ -n "$SF_CONFIG" ]] && fixer_args+=("--swiftformat-config" "$SF_CONFIG")
  python3 "$CUSTOM_FIXER" "${fixer_args[@]}" "${files[@]}"
else
  log "Skipped (--no-fix)"
fi

# ─── Step 2: SwiftFormat — pass 1 ────────────────────────────────────────────
step "2 / 5  SwiftFormat  (pass 1)"
log "Applies: indentation · spacing · blank lines · braces · trailing commas · import sorting"
$AUTO_FIX && run_swiftformat "SwiftFormat pass 1" || log "Skipped (--no-fix)"

# ─── Step 3: SwiftLint --fix ─────────────────────────────────────────────────
step "3 / 5  SwiftLint  (auto-fix)"
log "Applies: correctable lint rules — colon spacing · empty count · redundant self · etc."
$AUTO_FIX && run_swiftlint_fix || log "Skipped (--no-fix)"

# ─── Step 4: SwiftFormat — pass 2 ────────────────────────────────────────────
step "4 / 5  SwiftFormat  (pass 2)"
log "Cleans up any spacing or blank-line artifacts introduced by SwiftLint"
$AUTO_FIX && run_swiftformat "SwiftFormat pass 2" || log "Skipped (--no-fix)"

# ─── Step 5: SwiftLint lint — final report ───────────────────────────────────
step "5 / 5  SwiftLint  (lint report)"

sl_args=()
[[ -n "$SL_CONFIG" ]] && sl_args+=("--config" "$SL_CONFIG")

if $DRY_RUN; then
  log "[dry-run] $SL_BIN lint -- <file> × ${#files[@]}"
else
  lint_output=""
  for f in "${files[@]}"; do
    lint_output+="$("$SL_BIN" lint "${sl_args[@]}" --reporter emoji "$f" 2>&1 || true)"$'\n'
  done

  [[ -n "${lint_output// /}" ]] && echo "$lint_output"

  error_count=$(echo "$lint_output" | grep -c " error: "   || true)
  warn_count=$(echo  "$lint_output" | grep -c " warning: " || true)

  echo ""
  divider
  if [[ $error_count -gt 0 ]]; then
    err  "SwiftLint: $error_count error(s)  $warn_count warning(s) remaining"
    exit 1
  elif [[ $warn_count -gt 0 ]]; then
    warn "SwiftLint: 0 errors  $warn_count warning(s) remaining"
  else
    ok   "SwiftLint: no violations ✓"
  fi
fi

divider
ok "All done ✓"
