#!/usr/bin/env bash
# tools/hodor-version.sh
# Doctor: prints the installed Hodor version + paths + hook wiring + recent errors.
# Run this when reporting a problem and paste the final JSON line.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIHOOKS_ROOT="$ROOT"
source "$ROOT/lib/common.sh"

VERSION="$(hooks_version)"
bi="$ROOT/build-info.json"
commit="unknown"; count=0; bdate=""
if [ -f "$bi" ] && command -v jq >/dev/null 2>&1; then
  commit="$(jq -r '.commit // "unknown"' "$bi" 2>/dev/null)"
  count="$(jq -r '.commitCount // 0' "$bi" 2>/dev/null)"
  bdate="$(jq -r '.buildDate // ""' "$bi" 2>/dev/null)"
fi

echo "Hodor - version check"
echo "  version    : $VERSION"
echo "  commit     : $commit"
echo "  commitCount: $count"
echo "  buildDate  : ${bdate:-(dev / not stamped)}"
echo "  root       : $ROOT"
echo "  config     : $ROOT/config/settings.json"
echo "  logs       : $LOG_DIR"
if [ -n "$OTEL_ENDPOINT" ]; then echo "  otel       : configured"; else echo "  otel       : not set (queued to disk)"; fi

claude="$HOME/.claude/settings.json"
if [ -f "$claude" ] && grep -q dispatch "$claude" 2>/dev/null; then
  echo "  claude hook : OK  ($claude)"
else
  echo "  claude hook : missing  ($claude)"
fi
copilot="$HOME/.copilot/hooks/company-hooks.json"
if [ -f "$copilot" ]; then echo "  copilot hook: OK  ($copilot)"; else echo "  copilot hook: missing  ($copilot)"; fi

if [ -f "$LOG_DIR/hooks-error.jsonl" ]; then
  echo "  recent errors:"
  tail -n 3 "$LOG_DIR/hooks-error.jsonl" | sed 's/^/    /'
fi

printf '{"name":"hodor","version":"%s","commit":"%s","commitCount":%s,"root":"%s"}\n' \
  "$(json_escape "$VERSION")" "$(json_escape "$commit")" "${count:-0}" "$(json_escape "$ROOT")"
