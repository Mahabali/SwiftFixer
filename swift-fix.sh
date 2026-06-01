#!/usr/bin/env bash
# =============================================================================
# swift-fix.sh
#
# Collect Swift files from either:
#   • git diff (default)
#   • files explicitly passed by the user
#
# Then runs in order:
#
#   1. swift_custom_fixes.py
#   2. swiftformat  (pass 1)
#   3. swiftlint --fix
#   4. swiftformat  (pass 2)
#   5. swiftlint lint
#
# Compatible with:
#   • macOS default Bash 3.2
#   • Linux Bash 4+
# =============================================================================

set -euo pipefail

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[info]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[ ok ]${RESET}  $*"; }
err()     { echo -e "${RED}[err ]${RESET}  $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}── $* ${RESET}"; }
divider() { echo -e "${BOLD}${CYAN}────────────────────────────────────────${RESET}"; }

# ─── Flags ───────────────────────────────────────────────────────────────────
DRY_RUN=false
AUTO_FIX=true
USE_GIT_DIFF=true

USER_FILES=()

# ─── Parse arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in

    --dry-run)
      DRY_RUN=true
      shift
      ;;

    --no-fix)
      AUTO_FIX=false
      shift
      ;;

    --files)
      USE_GIT_DIFF=false
      shift

      while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
        USER_FILES+=("$1")
        shift
      done
      ;;

    -h|--help)
      echo "Usage: $(basename "$0") [options] [swift files]"
      echo ""
      echo "Options:"
      echo "  --dry-run        Preview only"
      echo "  --no-fix         Skip auto-fixes"
      echo "  --files          Explicit Swift files"
      echo ""
      echo "Examples:"
      echo "  ./swift-fix.sh"
      echo "  ./swift-fix.sh File.swift"
      echo "  ./swift-fix.sh File1.swift File2.swift"
      echo "  ./swift-fix.sh --files Sources/A.swift Sources/B.swift"
      exit 0
      ;;

    *)
      USE_GIT_DIFF=false
      USER_FILES+=("$1")
      shift
      ;;
  esac
done

# ─── Locate configs ─────────────────────────────────────────────────────────
find_config() {
  local filename="$1"
  local dir

  dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$filename" ]]; then
      echo "$dir/$filename"
      return
    fi

    dir="$(dirname "$dir")"
  done

  echo ""
}

SF_CONFIG="$(find_config .swiftformat)"
SL_CONFIG="$(find_config .swiftlint.yml)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Prefer local tools first ───────────────────────────────────────────────
LOCAL_SWIFTFORMAT="./swiftformat"
LOCAL_SWIFTLINT="./swiftlint"
LOCAL_CUSTOM_FIXER="./swift_custom_fixes.py"

if [[ -x "$LOCAL_SWIFTFORMAT" ]]; then
  SWIFTFORMAT_BIN="$LOCAL_SWIFTFORMAT"
else
  SWIFTFORMAT_BIN="$(command -v swiftformat || true)"
fi

if [[ -x "$LOCAL_SWIFTLINT" ]]; then
  SWIFTLINT_BIN="$LOCAL_SWIFTLINT"
else
  SWIFTLINT_BIN="$(command -v swiftlint || true)"
fi

if [[ -f "$LOCAL_CUSTOM_FIXER" ]]; then
  CUSTOM_FIXER="$LOCAL_CUSTOM_FIXER"
else
  CUSTOM_FIXER="$SCRIPT_DIR/swift_custom_fixes.py"
fi

# ─── Dependency checks ──────────────────────────────────────────────────────
missing=()

command -v git     >/dev/null 2>&1 || missing+=("git")
command -v python3 >/dev/null 2>&1 || missing+=("python3 → brew install python3")

[[ -n "${SWIFTFORMAT_BIN:-}" ]] || missing+=("swiftformat → brew install swiftformat")
[[ -n "${SWIFTLINT_BIN:-}" ]]   || missing+=("swiftlint → brew install swiftlint")

if [[ ${#missing[@]} -gt 0 ]]; then
  err "Missing tools:"

  for m in "${missing[@]}"; do
    err "  • $m"
  done

  exit 1
fi

if [[ ! -f "$CUSTOM_FIXER" ]]; then
  err "swift_custom_fixes.py not found"
  err "Checked:"
  err "  • ./swift_custom_fixes.py"
  err "  • $SCRIPT_DIR/swift_custom_fixes.py"
  exit 1
fi

# ─── File collection helpers ────────────────────────────────────────────────
files=()

add_file() {
  local file="$1"

  [[ ! -f "$file" ]] && return

  local existing

  for existing in "${files[@]:-}"; do
    [[ "$existing" == "$file" ]] && return
  done

  files+=("$file")
}

# ─── Collect Swift files ────────────────────────────────────────────────────
if $USE_GIT_DIFF; then

  while IFS= read -r f; do
    add_file "$f"
  done < <(
    git diff          --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
    git diff --cached --name-only --diff-filter=ACMR -- '*.swift' 2>/dev/null
  )

else

  for f in "${USER_FILES[@]:-}"; do

    if [[ "$f" != *.swift ]]; then
      warn "Skipping non-swift file: $f"
      continue
    fi

    if [[ ! -f "$f" ]]; then
      warn "File not found: $f"
      continue
    fi

    add_file "$f"

  done
fi

# ─── No files ───────────────────────────────────────────────────────────────
if [[ ${#files[@]:-0} -eq 0 ]]; then
  warn "No Swift files found — nothing to do."
  exit 0
fi

divider

if $USE_GIT_DIFF; then
  log "Using Swift files from git diff"
else
  log "Using user-provided Swift files"
fi

log "Found ${#files[@]} Swift file(s):"

for f in "${files[@]:-}"; do
  echo "     • $f"
done

divider

# ─── SwiftFormat helper ─────────────────────────────────────────────────────
run_swiftformat() {

  local label="$1"
  shift || true

  local changed=0

  if $DRY_RUN; then
    log "[dry-run] swiftformat <${#files[@]} files>"
    return
  fi

  for f in "${files[@]:-}"; do

    local before
    local after

    before="$(
      md5 -q "$f" 2>/dev/null ||
      md5sum "$f" 2>/dev/null | awk '{print $1}'
    )"

    if [[ -n "${SF_CONFIG:-}" ]]; then
      "$SWIFTFORMAT_BIN" \
        --config "$SF_CONFIG" \
        "$f" 2>&1 \
          | grep -Ev "^(Running SwiftFormat|No files matched)" || true
    else
      "$SWIFTFORMAT_BIN" \
        "$f" 2>&1 \
          | grep -Ev "^(Running SwiftFormat|No files matched)" || true
    fi

    after="$(
      md5 -q "$f" 2>/dev/null ||
      md5sum "$f" 2>/dev/null | awk '{print $1}'
    )"

    if [[ "$before" != "$after" ]]; then
      log "  formatted → $f"
      changed=$((changed + 1))
    fi
  done

  if [[ $changed -eq 0 ]]; then
    ok "$label — no changes needed"
  else
    ok "$label — $changed file(s) updated"
  fi
}

# ─── Step 1 ─────────────────────────────────────────────────────────────────
step "1 / 5  Custom fixes"

if $DRY_RUN; then

  log "[dry-run] python3 swift_custom_fixes.py"

elif $AUTO_FIX; then

  fixer_args=()

  [[ -n "${SL_CONFIG:-}" ]] && fixer_args+=("--swiftlint-config" "$SL_CONFIG")
  [[ -n "${SF_CONFIG:-}" ]] && fixer_args+=("--swiftformat-config" "$SF_CONFIG")

  python3 "$CUSTOM_FIXER" \
    "${fixer_args[@]:-}" \
    "${files[@]:-}"

else

  log "Skipped (--no-fix)"

fi

# ─── Step 2 ─────────────────────────────────────────────────────────────────
step "2 / 5  SwiftFormat (pass 1)"

if $AUTO_FIX; then
  run_swiftformat "SwiftFormat pass 1"
else
  log "Skipped (--no-fix)"
fi

# ─── Step 3 ─────────────────────────────────────────────────────────────────
step "3 / 5  SwiftLint (auto-fix)"

sl_args=()
[[ -n "${SL_CONFIG:-}" ]] && sl_args+=("--config" "$SL_CONFIG")

if $DRY_RUN; then

  log "[dry-run] swiftlint --fix"

elif $AUTO_FIX; then

  "$SWIFTLINT_BIN" \
    --fix \
    "${sl_args[@]:-}" \
    "${files[@]:-}" 2>&1 \
      | grep -Ev "^(Done linting|Linting)" || true

  ok "SwiftLint auto-fix done"

else

  log "Skipped (--no-fix)"

fi

# ─── Step 4 ─────────────────────────────────────────────────────────────────
step "4 / 5  SwiftFormat (pass 2)"

if $AUTO_FIX; then
  run_swiftformat "SwiftFormat pass 2"
else
  log "Skipped (--no-fix)"
fi

# ─── Step 5 ─────────────────────────────────────────────────────────────────
step "5 / 5  SwiftLint (lint report)"

if $DRY_RUN; then

  log "[dry-run] swiftlint lint"

else

  lint_output="$(
    "$SWIFTLINT_BIN" lint \
      "${sl_args[@]:-}" \
      --reporter emoji \
      "${files[@]:-}" 2>&1 || true
  )"

  [[ -n "$lint_output" ]] && echo "$lint_output"

  error_count=$(echo "$lint_output" | grep -c " error: " || true)
  warn_count=$(echo "$lint_output" | grep -c " warning: " || true)

  echo ""
  divider

  if [[ $error_count -gt 0 ]]; then

    err "SwiftLint: $error_count error(s)  $warn_count warning(s) remaining"
    echo ""
    exit 1

  elif [[ $warn_count -gt 0 ]]; then

    warn "SwiftLint: 0 errors  $warn_count warning(s) remaining"

  else

    ok "SwiftLint: no violations ✓"

  fi
fi

divider
ok "All done ✓"