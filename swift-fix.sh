#!/usr/bin/env bash
# =============================================================================
# swift-fix.sh
# Three ways to specify which files to process:
#
#   1. No path args    — staged + unstaged files from git diff in current dir
#   2. REPO_PATH       — staged + unstaged files from git diff in that repo
#   3. File(s)         — exactly those .swift files, no git diff involved
#
# Pipeline (all modes):
#   1. swift_custom_fixes.py  — param expansion, line-length, filter→first, etc.
#   2. swiftformat  (pass 1)  — spacing, indentation, blank lines, imports
#   3. swiftlint --fix        — auto-correctable lint violations
#   4. swiftformat  (pass 2)  — clean up artifacts from SwiftLint
#   5. swiftlint lint         — final report (errors block, warnings don't)
#
# Usage:
#   ./swift-fix.sh                                   # git diff, current repo
#   ./swift-fix.sh ~/projects/MyApp                  # git diff, explicit repo
#   ./swift-fix.sh ~/projects/MyApp --dry-run
#   ./swift-fix.sh path/to/File.swift                # single file
#   ./swift-fix.sh File1.swift File2.swift File3.swift  # multiple files
#   ./swift-fix.sh File1.swift File2.swift --no-fix
# =============================================================================

set -euo pipefail

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

  No PATH args      Staged + unstaged Swift files from git diff (current repo)
  Single directory  Staged + unstaged Swift files from git diff in that repo
  .swift file(s)    Process exactly those files — no git diff involved

Options:
  --dry-run   Show which files would be processed, make no changes
  --no-fix    Skip all auto-correct steps; report violations only
  -h, --help  Show this help

Examples:
  $(basename "$0")                                   # git diff, current dir
  $(basename "$0") ~/projects/MyApp                  # git diff, explicit repo
  $(basename "$0") ~/projects/MyApp --dry-run        # preview only
  $(basename "$0") Sources/Feature/MyView.swift      # single file
  $(basename "$0") File1.swift File2.swift           # multiple files
  $(basename "$0") File1.swift File2.swift --no-fix  # lint report only
EOF
      exit 0 ;;
    --*) err "Unknown option: $arg"; exit 1 ;;
    *)   POSITIONAL+=("$arg") ;;
  esac
done

# ─── Resolve what mode we're in ──────────────────────────────────────────────
# Expand ~ in every positional arg
expanded=()
for p in "${POSITIONAL[@]+"${POSITIONAL[@]}"}"; do
  expanded+=("${p/#\~/$HOME}")
done

declare -A seen
files=()   # will hold final list of absolute .swift paths
MODE=""

if [[ ${#expanded[@]} -eq 0 ]]; then
  # ── Mode 1: git diff in current directory ──────────────────────────────────
  MODE="git-diff"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Not inside a git repository. Pass a repo path or specific .swift files."; exit 1; }

elif [[ ${#expanded[@]} -eq 1 && -d "${expanded[0]}" ]]; then
  # ── Mode 2: git diff in an explicit repo path ──────────────────────────────
  MODE="git-diff"
  START_DIR="$(cd "${expanded[0]}" 2>/dev/null && pwd)" \
    || { err "Path does not exist: ${expanded[0]}"; exit 1; }
  REPO_ROOT="$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Not a git repository: $START_DIR"; exit 1; }

else
  # ── Mode 3: explicit .swift file(s) ───────────────────────────────────────
  MODE="explicit-files"
  for p in "${expanded[@]}"; do
    # Reject directories in this mode (mixed dirs+files not supported)
    if [[ -d "$p" ]]; then
      err "Cannot mix directory and file arguments. Pass either a repo path OR .swift files."
      exit 1
    fi
    abs="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" \
      || { err "File not found: $p"; exit 1; }
    [[ "$abs" == *.swift ]] || { warn "Skipping non-Swift file: $abs"; continue; }
    [[ -f "$abs" ]]          || { err "File not found: $abs"; exit 1; }
    [[ -z "${seen[$abs]+x}" ]] && { seen["$abs"]=1; files+=("$abs"); }
  done
  # Derive repo root from the first file's location (needed for configs)
  REPO_ROOT="$(git -C "$(dirname "${files[0]}")" rev-parse --show-toplevel 2>/dev/null)" \
    || { err "Files must be inside a git repository."; exit 1; }
fi

# ─── For git-diff modes: collect changed files ────────────────────────────────
if [[ "$MODE" == "git-diff" ]]; then
  cd "$REPO_ROOT"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    abs="$REPO_ROOT/$rel"
    [[ -f "$abs" && -z "${seen[$abs]+x}" ]] && { seen["$abs"]=1; files+=("$abs"); }
  done < <(
    git diff          --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
    git diff --cached --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
  )
fi

if [[ ${#files[@]} -eq 0 ]]; then
  warn "No Swift files to process — nothing to do."; exit 0
fi

# ─── Locate configs ───────────────────────────────────────────────────────────
find_config() {
  local filename="$1" dir="$REPO_ROOT"
  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/$filename" ]] && { echo "$dir/$filename"; return; }
    dir="$(dirname "$dir")"
  done
  echo ""
}

SF_CONFIG="$(find_config .swiftformat)"
SL_CONFIG="$(find_config .swiftlint.yml)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_FIXER="$SCRIPT_DIR/swift_custom_fixes.py"

# ─── Dependency check ────────────────────────────────────────────────────────
missing=()
command -v git         &>/dev/null || missing+=("git")
command -v python3     &>/dev/null || missing+=("python3      →  brew install python3")
command -v swiftformat &>/dev/null || missing+=("swiftformat  →  brew install swiftformat")
command -v swiftlint   &>/dev/null || missing+=("swiftlint    →  brew install swiftlint")

if [[ ${#missing[@]} -gt 0 ]]; then
  err "Missing tools:"; for m in "${missing[@]}"; do err "  • $m"; done; exit 1
fi

if [[ ! -f "$CUSTOM_FIXER" ]]; then
  err "swift_custom_fixes.py not found at $CUSTOM_FIXER"; exit 1
fi

# ─── Summary header ──────────────────────────────────────────────────────────
divider
log "Repo : $REPO_ROOT"
if [[ "$MODE" == "git-diff" ]]; then
  log "Mode : git diff (staged + unstaged)"
else
  log "Mode : explicit file(s)"
fi
log "Files: ${#files[@]}"
for f in "${files[@]}"; do echo "     • ${f#"$REPO_ROOT"/}"; done
divider

# ─── Reusable SwiftFormat runner ─────────────────────────────────────────────
run_swiftformat() {
  local label="$1"
  local sf_args=()
  [[ -n "$SF_CONFIG" ]] && sf_args+=("--config" "$SF_CONFIG")

  if $DRY_RUN; then
    log "[dry-run] swiftformat ${sf_args[*]:-<no config>} -- <file> × ${#files[@]}"
    return
  fi

  local changed=0
  for f in "${files[@]}"; do
    local before after
    before="$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')"
    swiftformat "${sf_args[@]}" -- "$f" 2>&1 \
      | grep -Ev "^(Running SwiftFormat|No files matched|1 file formatted)" || true
    after="$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')"
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
    log "[dry-run] swiftlint --fix ${sl_args[*]:-<no config>} -- <file> × ${#files[@]}"
    return
  fi

  local changed=0
  for f in "${files[@]}"; do
    local before after
    before="$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')"
    swiftlint --fix "${sl_args[@]}" -- "$f" 2>&1 \
      | grep -Ev "^(Done linting|Linting ')" || true
    after="$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')"
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
  log "[dry-run] swiftlint lint -- <file> × ${#files[@]}"
else
  lint_output=""
  for f in "${files[@]}"; do
    lint_output+="$(swiftlint lint "${sl_args[@]}" --reporter emoji -- "$f" 2>&1 || true)"$'\n'
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
