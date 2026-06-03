#!/usr/bin/env python3
"""
swift_custom_fixes.py
Applies custom Swift fixes that SwiftLint cannot fully auto-correct.

Fixes applied:
  LINE LENGTH
    line_length              — breaks long lines at safe points, re-indents

  COLLECTION / SEQUENCE
    first_where              — .filter { }.first       → .first { }
    last_where               — .filter { }.last        → .last { }
    contains_over_first_not_nil — .first { } != nil   → .contains { }
    contains_over_filter_count  — .filter { }.count > 0 → .contains { }
    contains_over_filter_is_empty — .filter { }.isEmpty → !contains { }

  EMPTINESS
    empty_count              — .count == 0 / > 0 / != 0 → .isEmpty / !.isEmpty
    empty_string             — == ""  / != ""            → .isEmpty / !.isEmpty
    empty_collection_literal — == []  / == [:]           → .isEmpty / !.isEmpty

  BOOL
    toggle_bool              — x = !x → x.toggle()

  OPTIONAL BINDING
    shorthand_optional_binding — if let x = x → if let x  (Swift 5.7+)

  LEGACY RANDOM
    legacy_random            — arc4random_uniform(n) → Int.random(in: 0..<n)
                               drand48()             → Double.random(in: 0.0..<1.0)

  ZERO INIT
    prefer_zero_over_explicit_init — CGPoint(x:0,y:0) / CGSize(width:0,height:0)
                                     CGRect(x:0,y:0,width:0,height:0) → .zero

Usage:
  python3 swift_custom_fixes.py FILE [FILE ...]
      [--max-len N]
      [--swiftlint-config PATH]
      [--swiftformat-config PATH]
"""

import argparse
import os
import re
import sys
from typing import Optional

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN  = "\033[0;32m"; YELLOW = "\033[1;33m"; RED = "\033[0;31m"
CYAN   = "\033[0;36m"; RESET  = "\033[0m"

def log(msg):  print(f"{CYAN}[fix]{RESET}  {msg}")
def ok(msg):   print(f"{GREEN}[ ok]{RESET}  {msg}")
def warn(msg): print(f"{YELLOW}[warn]{RESET} {msg}", file=sys.stderr)


# ════════════════════════════════════════════════════════════════════════════
#  Config parsing
# ════════════════════════════════════════════════════════════════════════════

def read_max_len(swiftlint: Optional[str], swiftformat: Optional[str]) -> int:
    if swiftlint and os.path.exists(swiftlint):
        text = open(swiftlint).read()
        m = re.search(r'line_length\s*:\s*\n\s+warning\s*:\s*(\d+)', text)
        if m: return int(m.group(1))
        m = re.search(r'line_length\s*:\s*(\d+)', text)
        if m: return int(m.group(1))
    if swiftformat and os.path.exists(swiftformat):
        m = re.search(r'--maxwidth\s+(\d+)', open(swiftformat).read())
        if m: return int(m.group(1))
    return 120


def read_indent_style(swiftformat: Optional[str]) -> str:
    if swiftformat and os.path.exists(swiftformat):
        text = open(swiftformat).read()
        if re.search(r'--indent\s+tab', text): return "\t"
        m = re.search(r'--indent\s+(\d+)', text)
        if m: return " " * int(m.group(1))
    return "    "


# ════════════════════════════════════════════════════════════════════════════
#  Tokeniser helpers
# ════════════════════════════════════════════════════════════════════════════

def safe_positions(line: str):
    """Yield indices NOT inside a string literal or line comment."""
    i, n = 0, len(line)
    while i < n:
        if line[i] == "/" and i + 1 < n and line[i+1] == "/":
            return
        if line[i] == "#" and i + 1 < n and line[i+1] == '"':
            end = line.find('"#', i + 2)
            i = (end + 2) if end != -1 else n
            continue
        if line[i] == '"':
            i += 1
            while i < n:
                if line[i] == "\\" and i + 1 < n: i += 2; continue
                if line[i] == '"':                i += 1; break
                i += 1
            continue
        yield i
        i += 1

def safe_set(line: str) -> set:
    return set(safe_positions(line))


# ════════════════════════════════════════════════════════════════════════════
#  Helper: apply a list of (pattern, replacer) pairs to every line
# ════════════════════════════════════════════════════════════════════════════

def apply_patterns(content: str, patterns: list) -> tuple:
    total = 0
    for pattern, replacer in patterns:
        new_content, n = pattern.subn(replacer, content)
        content = new_content
        total += n
    return content, total


# ════════════════════════════════════════════════════════════════════════════
#  Fix: first_where  +  last_where
# ════════════════════════════════════════════════════════════════════════════
# .filter { body }.first  → .first { body }
# .filter { body }.last   → .last  { body }
# .filter({ body }).first → .first(where: { body })
# .filter({ body }).last  → .last(where:  { body })

_AFTER = r'(?P<after>!|\s*\?\?[^\n,]*)?\b'

FILTER_FIRST_LAST_PATTERNS = [
    # trailing closure syntax + .first or .last
    (
        re.compile(
            r'\.filter\s*\{\s*(?P<body>[^{}]+?)\s*\}'
            r'\.(?P<method>first|last)' + _AFTER
        ),
        lambda m: f'.{m.group("method")} {{ {m.group("body").strip()} }}{m.group("after") or ""}'
    ),
    # parenthesised closure + .first or .last
    (
        re.compile(
            r'\.filter\(\{\s*(?P<body>[^{}]+?)\s*\}\)'
            r'\.(?P<method>first|last)' + _AFTER
        ),
        lambda m: (
            f'.{m.group("method")}(where: {{ {m.group("body").strip()} }})'
            f'{m.group("after") or ""}'
        )
    ),
]

def fix_filter_first_last(content: str) -> tuple:
    return apply_patterns(content, FILTER_FIRST_LAST_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: contains_over_first_not_nil
# ════════════════════════════════════════════════════════════════════════════
# .first { body } != nil  →  .contains { body }
# .first { body } == nil  →  !.contains { body }    (less common but valid)
# .first(where: { body }) != nil  →  .contains(where: { body })

CONTAINS_OVER_FIRST_PATTERNS = [
    (
        re.compile(
            r'\.first\s*\{\s*(?P<body>[^{}]+?)\s*\}\s*!=\s*nil'
        ),
        lambda m: f'.contains {{ {m.group("body").strip()} }}'
    ),
    (
        re.compile(
            r'\.first\(where:\s*\{\s*(?P<body>[^{}]+?)\s*\}\)\s*!=\s*nil'
        ),
        lambda m: f'.contains(where: {{ {m.group("body").strip()} }})'
    ),
    (
        re.compile(
            r'nil\s*!=\s*\.first\s*\{\s*(?P<body>[^{}]+?)\s*\}'
        ),
        lambda m: f'.contains {{ {m.group("body").strip()} }}'
    ),
]

def fix_contains_over_first_not_nil(content: str) -> tuple:
    return apply_patterns(content, CONTAINS_OVER_FIRST_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: contains_over_filter_count  +  contains_over_filter_is_empty
# ════════════════════════════════════════════════════════════════════════════
# .filter { body }.count > 0   →  .contains { body }
# .filter { body }.count != 0  →  .contains { body }
# .filter { body }.count == 0  →  !.contains { body }
# .filter { body }.isEmpty     →  !.contains { body }
# !.filter { body }.isEmpty    →  .contains { body }
# .filter({ body }).count > 0  →  .contains(where: { body })
# etc.

def _rewrite_filter_contains(m: re.Match, use_where: bool, negate: bool) -> str:
    """
    Reconstruct the contains call, keeping the receiver that preceded .filter.
    The match object must expose group('pre') = the receiver expression before the dot,
    and group('body') = the closure body.
    e.g.  "arr.filter { $0.ok }.count == 0"
          pre='arr', body='$0.ok'  → '!arr.contains { $0.ok }'
    """
    pre  = m.group("pre")
    body = m.group("body").strip()
    bang = "!" if negate else ""
    if use_where:
        return f'{bang}{pre}.contains(where: {{ {body} }})'
    else:
        return f'{bang}{pre}.contains {{ {body} }}'

# Receiver pattern: word chars, optional self., optional ? or []
_REC = r'(?P<pre>[a-zA-Z_][a-zA-Z0-9_?.\[\]]*)'

CONTAINS_OVER_FILTER_PATTERNS = [
    # !receiver.filter { body }.isEmpty  (negated isEmpty = non-empty)
    (
        re.compile(_REC + r'\.filter\s*\{\s*(?P<body>[^{}]+?)\s*\}\.isEmpty'),
        lambda m: _rewrite_filter_contains(m, use_where=False, negate=True)
    ),
    # receiver.filter { body }.count > 0 / != 0  (non-empty)
    (
        re.compile(_REC + r'\.filter\s*\{\s*(?P<body>[^{}]+?)\s*\}\.count\s*(?:>|!=)\s*0'),
        lambda m: _rewrite_filter_contains(m, use_where=False, negate=False)
    ),
    # receiver.filter { body }.count == 0  (empty)
    (
        re.compile(_REC + r'\.filter\s*\{\s*(?P<body>[^{}]+?)\s*\}\.count\s*==\s*0'),
        lambda m: _rewrite_filter_contains(m, use_where=False, negate=True)
    ),
    # receiver.filter { body }.isEmpty  (empty — no leading !)
    (
        re.compile(_REC + r'\.filter\s*\{\s*(?P<body>[^{}]+?)\s*\}\.isEmpty'),
        lambda m: _rewrite_filter_contains(m, use_where=False, negate=True)
    ),
    # parenthesised closure variants
    (
        re.compile(_REC + r'\.filter\(\{\s*(?P<body>[^{}]+?)\s*\}\)\.count\s*(?:>|!=)\s*0'),
        lambda m: _rewrite_filter_contains(m, use_where=True, negate=False)
    ),
    (
        re.compile(_REC + r'\.filter\(\{\s*(?P<body>[^{}]+?)\s*\}\)\.count\s*==\s*0'),
        lambda m: _rewrite_filter_contains(m, use_where=True, negate=True)
    ),
    (
        re.compile(_REC + r'\.filter\(\{\s*(?P<body>[^{}]+?)\s*\}\)\.isEmpty'),
        lambda m: _rewrite_filter_contains(m, use_where=True, negate=True)
    ),
]

def fix_contains_over_filter(content: str) -> tuple:
    return apply_patterns(content, CONTAINS_OVER_FILTER_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: empty_count
# ════════════════════════════════════════════════════════════════════════════
# expr.count == 0  →  expr.isEmpty
# expr.count != 0  →  !expr.isEmpty
# expr.count > 0   →  !expr.isEmpty
# 0 == expr.count  →  expr.isEmpty
# 0 != expr.count  →  !expr.isEmpty
# 0 < expr.count   →  !expr.isEmpty

_EXPR = r'(?P<expr>[a-zA-Z_][a-zA-Z0-9_.?()\[\]]*)'

EMPTY_COUNT_PATTERNS = [
    (re.compile(_EXPR + r'\.count\s*==\s*0\b'),  lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\.count\s*!=\s*0\b'),  lambda m: f'!{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\.count\s*>\s*0\b'),   lambda m: f'!{m.group("expr")}.isEmpty'),
    (re.compile(r'0\s*==\s*' + _EXPR + r'\.count\b'), lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(r'0\s*!=\s*' + _EXPR + r'\.count\b'), lambda m: f'!{m.group("expr")}.isEmpty'),
    (re.compile(r'0\s*<\s*'  + _EXPR + r'\.count\b'), lambda m: f'!{m.group("expr")}.isEmpty'),
]

def fix_empty_count(content: str) -> tuple:
    return apply_patterns(content, EMPTY_COUNT_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: empty_string
# ════════════════════════════════════════════════════════════════════════════
# expr == ""  →  expr.isEmpty
# expr != ""  →  !expr.isEmpty

EMPTY_STRING_PATTERNS = [
    (re.compile(_EXPR + r'\s*==\s*""'),  lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\s*!=\s*""'),  lambda m: f'!{m.group("expr")}.isEmpty'),
    (re.compile(r'""' + r'\s*==\s*' + _EXPR), lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(r'""' + r'\s*!=\s*' + _EXPR), lambda m: f'!{m.group("expr")}.isEmpty'),
]

def fix_empty_string(content: str) -> tuple:
    return apply_patterns(content, EMPTY_STRING_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: empty_collection_literal
# ════════════════════════════════════════════════════════════════════════════
# expr == []   →  expr.isEmpty
# expr != []   →  !expr.isEmpty
# expr == [:]  →  expr.isEmpty
# expr != [:]  →  !expr.isEmpty

EMPTY_COLLECTION_PATTERNS = [
    (re.compile(_EXPR + r'\s*==\s*\[\]'),   lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\s*!=\s*\[\]'),   lambda m: f'!{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\s*==\s*\[:\]'),  lambda m: f'{m.group("expr")}.isEmpty'),
    (re.compile(_EXPR + r'\s*!=\s*\[:\]'),  lambda m: f'!{m.group("expr")}.isEmpty'),
]

def fix_empty_collection(content: str) -> tuple:
    return apply_patterns(content, EMPTY_COLLECTION_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: toggle_bool
# ════════════════════════════════════════════════════════════════════════════
# foo = !foo           →  foo.toggle()
# self.foo = !self.foo →  self.foo.toggle()
# Must match: LHS identifier == RHS (after '!'), same token.

_TOGGLE_RE = re.compile(
    r'\b(?P<lhs>(?:self\.)?[a-zA-Z_][a-zA-Z0-9_.]*)\s*=\s*!(?P=lhs)\b'
)

def fix_toggle_bool(content: str) -> tuple:
    new_content, n = _TOGGLE_RE.subn(lambda m: f'{m.group("lhs")}.toggle()', content)
    return new_content, n


# ════════════════════════════════════════════════════════════════════════════
#  Fix: shorthand_optional_binding  (Swift 5.7+)
# ════════════════════════════════════════════════════════════════════════════
# if let foo = foo {          →  if let foo {
# if let foo = foo,           →  if let foo,
# guard let foo = foo else {  →  guard let foo else {
# Also handles: if var x = x

_OPT_BIND_RE = re.compile(
    r'\b(?P<kw>let|var)\s+(?P<name>[a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(?P=name)\b'
)

def fix_shorthand_optional_binding(content: str) -> tuple:
    new_content, n = _OPT_BIND_RE.subn(
        lambda m: f'{m.group("kw")} {m.group("name")}',
        content
    )
    return new_content, n


# ════════════════════════════════════════════════════════════════════════════
#  Fix: legacy_random
# ════════════════════════════════════════════════════════════════════════════
# arc4random_uniform(n)  →  Int.random(in: 0..<n)
# arc4random()           →  Int.random(in: 0..<Int.max)
# drand48()              →  Double.random(in: 0.0..<1.0)

LEGACY_RANDOM_PATTERNS = [
    (
        re.compile(r'\barc4random_uniform\s*\(\s*(?P<n>[^)]+?)\s*\)'),
        lambda m: f'Int.random(in: 0..<{m.group("n").strip()})'
    ),
    (
        re.compile(r'\barc4random\s*\(\s*\)'),
        lambda _: 'Int.random(in: 0..<Int.max)'
    ),
    (
        re.compile(r'\bdrand48\s*\(\s*\)'),
        lambda _: 'Double.random(in: 0.0..<1.0)'
    ),
]

def fix_legacy_random(content: str) -> tuple:
    return apply_patterns(content, LEGACY_RANDOM_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: prefer_zero_over_explicit_init
# ════════════════════════════════════════════════════════════════════════════
# CGPoint(x: 0, y: 0)                         →  .zero
# CGSize(width: 0, height: 0)                  →  .zero
# CGRect(x: 0, y: 0, width: 0, height: 0)     →  .zero
# CGVector(dx: 0, dy: 0)                       →  .zero
# UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) → .zero

_Z = r'\s*0(?:\.0)?\s*'   # matches 0 or 0.0

PREFER_ZERO_PATTERNS = [
    (
        re.compile(r'\bCGPoint\s*\(\s*x:' + _Z + r',\s*y:' + _Z + r'\)'),
        lambda _: '.zero'
    ),
    (
        re.compile(r'\bCGSize\s*\(\s*width:' + _Z + r',\s*height:' + _Z + r'\)'),
        lambda _: '.zero'
    ),
    (
        re.compile(
            r'\bCGRect\s*\(\s*x:' + _Z + r',\s*y:' + _Z +
            r',\s*width:' + _Z + r',\s*height:' + _Z + r'\)'
        ),
        lambda _: '.zero'
    ),
    (
        re.compile(r'\bCGVector\s*\(\s*dx:' + _Z + r',\s*dy:' + _Z + r'\)'),
        lambda _: '.zero'
    ),
    (
        re.compile(
            r'\bUIEdgeInsets\s*\(\s*top:' + _Z + r',\s*left:' + _Z +
            r',\s*bottom:' + _Z + r',\s*right:' + _Z + r'\)'
        ),
        lambda _: '.zero'
    ),
]

def fix_prefer_zero(content: str) -> tuple:
    return apply_patterns(content, PREFER_ZERO_PATTERNS)


# ════════════════════════════════════════════════════════════════════════════
#  Fix: line_length
#
#  Strategy (tried in order for each long line):
#    1. expand_params  — function defs / calls with multiple params get each
#                        param on its own indented line, closing ) on its own
#                        line aligned to the call site. This is tried first
#                        because it produces the most readable Swift output.
#    2. break_before_dot   — long method chains
#    3. break_before_operator — long boolean / ternary expressions
#    4. warn and leave    — string interpolations etc. we can't safely split
# ════════════════════════════════════════════════════════════════════════════

def leading_whitespace(line: str) -> str:
    return line[: len(line) - len(line.lstrip())]


# ── Paren helpers ─────────────────────────────────────────────────────────────

def find_matching_close(line: str, open_pos: int, open_ch: str, close_ch: str) -> int:
    """Return index of the close_ch that matches open_ch at open_pos, or -1."""
    depth = 0
    safe  = safe_set(line)
    for i in range(open_pos, len(line)):
        if i not in safe:
            continue
        if line[i] == open_ch:
            depth += 1
        elif line[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return -1


def split_top_level_params(params_str: str) -> list:
    """
    Split 'a: T, b: [T], c: (T) -> U' into individual param strings,
    respecting nested parens, brackets, angle brackets, and braces.
    """
    params  = []
    current = []
    pd = bd = ad = cd = 0   # paren / bracket / angle / brace depth
    safe = safe_set(params_str)

    for i, ch in enumerate(params_str):
        if i not in safe:
            current.append(ch)
            continue
        if   ch == "(": pd += 1
        elif ch == ")": pd -= 1
        elif ch == "[": bd += 1
        elif ch == "]": bd -= 1
        elif ch == "<": ad += 1
        elif ch == ">": ad -= 1
        elif ch == "{": cd += 1
        elif ch == "}": cd -= 1
        elif ch == "," and pd == 0 and bd == 0 and ad == 0 and cd == 0:
            params.append("".join(current).strip())
            current = []
            continue
        current.append(ch)

    if current:
        params.append("".join(current).strip())
    return [p for p in params if p]


# ── Core expander ─────────────────────────────────────────────────────────────

def expand_params(line: str, max_len: int, indent_unit: str) -> Optional[list]:
    """
    When a line exceeds max_len and contains a function definition or call
    with multiple comma-separated parameters, expand to one-param-per-line:

      func foo(a: Int, b: String) -> Bool {
      →
      func foo(
          a: Int,
          b: String
      ) -> Bool {

      let x = bar(arg1: a, arg2: b, arg3: c)
      →
      let x = bar(
          arg1: a,
          arg2: b,
          arg3: c
      )

    If the line is already within max_len, returns None.
    Also returns None if no expandable paren group is found.
    """
    if len(line) <= max_len:
        return None

    stripped = line.lstrip()
    # Never touch comments, imports, multi-line strings
    if (stripped.startswith("//") or stripped.startswith("*")
            or stripped.startswith("import ") or '"""' in line):
        return None

    base_indent  = leading_whitespace(line)
    param_indent = base_indent + indent_unit
    safe         = safe_set(line)

    pd = bd = 0

    # Walk the line looking for the first ( at depth 0 that:
    #   • contains at least one comma (multiple params)
    #   • has a matching close paren
    for i, ch in enumerate(line):
        if i not in safe:
            continue

        if ch == "[": bd += 1
        elif ch == "]": bd -= 1
        elif ch == "(" and bd == 0 and pd == 0:
            close = find_matching_close(line, i, "(", ")")
            if close == -1:
                pd += 1
                continue

            inner = line[i + 1 : close]
            params = split_top_level_params(inner)

            if len(params) < 2:
                # Single param — not worth expanding; keep scanning
                pd += 1
                continue

            # Found the group to expand
            before = line[: i + 1]          # ...funcName(
            after  = line[close:]            # ) -> ReturnType { or just )...

            result_lines = [before]
            for idx, param in enumerate(params):
                comma = "," if idx < len(params) - 1 else ""
                result_lines.append(param_indent + param + comma)
            result_lines.append(base_indent + after)

            # Recursively expand the closing-paren line if it's still too long
            # (e.g. ") -> VeryLongReturnType {" — rare but handled)
            final = []
            for part in result_lines[:-1]:
                final.append(part)
            last = result_lines[-1]
            if len(last) > max_len:
                final.extend(expand_params(last, max_len, indent_unit) or [last])
            else:
                final.append(last)

            return final

        elif ch == "(":
            pd += 1
        elif ch == ")":
            pd -= 1

    return None


# ── Fallback breakers (chains and operators) ──────────────────────────────────

def find_break_before_dot(line: str, limit: int) -> int:
    """Rightmost dot-chain break point at paren-depth 0, within limit chars."""
    safe = safe_set(line)
    pd = bd = 0
    best = -1
    for i, ch in enumerate(line[:limit]):
        if i not in safe: continue
        if   ch == "(": pd += 1
        elif ch == ")": pd -= 1
        elif ch == "[": bd += 1
        elif ch == "]": bd -= 1
        elif (ch == "." and pd == 0 and bd == 0
              and i > 0 and i + 1 < len(line) and line[i + 1].isalpha()):
            best = i
    return best


def find_break_before_operator(line: str, limit: int) -> int:
    """Rightmost top-level binary operator break point within limit chars."""
    ops  = ["&&", "||", "??", "+ ", "- ", "? "]
    safe = safe_set(line)
    pd = bd = 0
    best = -1
    for i, ch in enumerate(line[:limit]):
        if i not in safe: continue
        if   ch == "(": pd += 1
        elif ch == ")": pd -= 1
        elif ch == "[": bd += 1
        elif ch == "]": bd -= 1
        elif pd == 0 and bd == 0:
            for op in ops:
                if line[i : i + len(op)] == op:
                    best = i
                    break
    return best


def break_line(line: str, max_len: int, indent_unit: str) -> list:
    """
    Try expand_params first (function params one-per-line), then fall back
    to dot-chain and operator breaks.
    """
    if len(line) <= max_len:
        return [line]

    stripped = line.lstrip()
    if (stripped.startswith("//") or stripped.startswith("*")
            or stripped.startswith("import ") or '"""' in line):
        return [line]

    base_indent = leading_whitespace(line)
    cont_indent = base_indent + indent_unit

    # ── Strategy 1: expand function / call parameters ─────────────────────────
    expanded = expand_params(line, max_len, indent_unit)
    if expanded:
        return expanded

    # ── Strategy 2: break before a dot chain ──────────────────────────────────
    pos = find_break_before_dot(line, max_len)
    if pos > 0:
        head = line[:pos].rstrip()
        tail = cont_indent + line[pos:]
        return break_line(head, max_len, indent_unit) + break_line(tail, max_len, indent_unit)

    # ── Strategy 3: break before a binary operator ────────────────────────────
    pos = find_break_before_operator(line, max_len)
    if pos > 0:
        head = line[:pos].rstrip()
        tail = cont_indent + line[pos:]
        return break_line(head, max_len, indent_unit) + break_line(tail, max_len, indent_unit)

    warn(f"  Cannot safely break ({len(line)} chars): {line[:80]}…")
    return [line]


def fix_line_length(content: str, max_len: int, indent_unit: str) -> tuple:
    lines = content.split("\n")
    out   = []
    broken = 0
    for line in lines:
        if len(line) > max_len:
            parts = break_line(line, max_len, indent_unit)
            out.extend(parts)
            if len(parts) > 1:
                broken += 1
        else:
            out.append(line)
    return "\n".join(out), broken


# ════════════════════════════════════════════════════════════════════════════
#  Orchestrator
# ════════════════════════════════════════════════════════════════════════════

FIXERS = [
    # (function,                          label)
    (fix_filter_first_last,               "first_where / last_where"),
    (fix_contains_over_first_not_nil,     "contains_over_first_not_nil"),
    (fix_contains_over_filter,            "contains_over_filter_count/is_empty"),
    (fix_empty_count,                     "empty_count"),
    (fix_empty_string,                    "empty_string"),
    (fix_empty_collection,                "empty_collection_literal"),
    (fix_toggle_bool,                     "toggle_bool"),
    (fix_shorthand_optional_binding,      "shorthand_optional_binding"),
    (fix_legacy_random,                   "legacy_random"),
    (fix_prefer_zero,                     "prefer_zero_over_explicit_init"),
]


def process_file(path: str, max_len: int, indent_unit: str) -> dict:
    """Return a dict of {label: count} for every rule that fired, empty dict if unreadable."""
    try:
        original = open(path, encoding="utf-8").read()
    except OSError as e:
        warn(f"Cannot read {path}: {e}"); return {}

    content  = original
    counts   = {}

    for fixer, label in FIXERS:
        content, count = fixer(content)
        if count:
            counts[label] = counts.get(label, 0) + count

    content, ll = fix_line_length(content, max_len, indent_unit)
    if ll:
        counts["line_length"] = counts.get("line_length", 0) + ll

    if content == original:
        return {}

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return counts


def print_summary(grand_total: dict, files_changed: int, files_total: int) -> None:
    CYAN  = "\033[0;36m"; GREEN = "\033[0;32m"; YELLOW = "\033[1;33m"
    BOLD  = "\033[1m";    RESET = "\033[0m"

    print(f"\n{BOLD}{CYAN}────────────────────────────────────────{RESET}")
    print(f"{BOLD}  Fix Summary{RESET}")
    print(f"{BOLD}{CYAN}────────────────────────────────────────{RESET}")

    if not grand_total:
        print(f"  {YELLOW}No fixes applied.{RESET}")
    else:
        # Find the longest rule name for alignment
        col = max(len(label) for label in grand_total) + 2
        total_fixes = 0
        for label, count in sorted(grand_total.items(), key=lambda x: -x[1]):
            bar   = "█" * min(count, 30)
            print(f"  {GREEN}{label:<{col}}{RESET}  {count:>4}  {bar}")
            total_fixes += count
        print(f"{BOLD}{CYAN}────────────────────────────────────────{RESET}")
        print(f"  {'Total fixes':<{col}}  {BOLD}{total_fixes:>4}{RESET}")

    print(f"\n  Files modified : {BOLD}{files_changed}/{files_total}{RESET}")
    print(f"{BOLD}{CYAN}────────────────────────────────────────{RESET}\n")


def main():
    ap = argparse.ArgumentParser(description="Custom Swift source fixes")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--max-len",            type=int, default=0)
    ap.add_argument("--swiftlint-config",   default="")
    ap.add_argument("--swiftformat-config", default="")
    args = ap.parse_args()

    max_len     = args.max_len or read_max_len(args.swiftlint_config or None,
                                               args.swiftformat_config or None)
    indent_unit = read_indent_style(args.swiftformat_config or None)

    log(f"Line-length limit : {max_len}")
    log(f"Indent unit       : {repr(indent_unit)}")

    swift_files  = [p for p in args.files if p.endswith(".swift") and os.path.isfile(p)]
    grand_total  = {}
    files_changed = 0

    for path in swift_files:
        counts = process_file(path, max_len, indent_unit)
        if counts:
            files_changed += 1
            # Print per-file detail
            file_total = sum(counts.values())
            log(f"{path}  ({file_total} fix{'es' if file_total != 1 else ''})")
            for label, count in counts.items():
                print(f"     {'·'} {label}: {count}")
            # Accumulate into grand total
            for label, count in counts.items():
                grand_total[label] = grand_total.get(label, 0) + count

    print_summary(grand_total, files_changed, len(swift_files))


if __name__ == "__main__":
    sys.exit(main())
