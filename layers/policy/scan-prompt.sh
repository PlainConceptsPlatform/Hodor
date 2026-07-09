#!/usr/bin/env bash
# layers/policy/scan-prompt.sh - scans the prompt against patterns.d
# Usage: scan-prompt.sh "<prompt>"  (AIHOOKS_ROOT must be exported, or it is auto-detected)
# Output: one line per finding -> RULE|SEVERITY|EVIDENCE

PROMPT="$1"
ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -z "$PROMPT" ] && exit 0

PLACEHOLDER_RE='(example|placeholder|your_|xxxx|changeme|todo|fixme|dummy|fake|test_key|sample|lorem)'
ALLOWLIST="$ROOT/config/allowlist.txt"

luhn_valid() {
  local digits sum=0 alt=0 i d
  digits="$(printf '%s' "$1" | tr -cd '0-9')"
  [ "${#digits}" -lt 13 ] || [ "${#digits}" -gt 19 ] && return 1
  for ((i = ${#digits} - 1; i >= 0; i--)); do
    d=${digits:$i:1}
    if [ $alt -eq 1 ]; then d=$((d * 2)); [ $d -gt 9 ] && d=$((d - 9)); fi
    sum=$((sum + d)); alt=$((1 - alt))
  done
  [ $((sum % 10)) -eq 0 ]
}

in_allowlist() {
  [ -f "$ALLOWLIST" ] || return 1
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//')"
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac
    case "$lower" in *"$entry"*) return 0 ;; esac
  done < "$ALLOWLIST"
  return 1
}

for pfile in "$ROOT"/layers/policy/patterns.d/*.txt; do
  [ -f "$pfile" ] || continue
  while IFS='|' read -r name sev re; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    [ -z "$re" ] && continue
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      printf '%s' "$match" | grep -qiE "$PLACEHOLDER_RE" && continue
      in_allowlist "$match" && continue
      if [ "$name" = "CREDIT_CARD" ]; then luhn_valid "$match" || continue; fi
      printf '%s|%s|%s\n' "$name" "$sev" "$match"
    done < <(printf '%s' "$PROMPT" | grep -oiE "$re" 2>/dev/null)
  done < "$pfile"
done
exit 0
