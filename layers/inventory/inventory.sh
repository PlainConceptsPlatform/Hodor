#!/usr/bin/env bash
# layers/inventory/inventory.sh - snapshot of what this user has installed (needs jq; prints nothing without it).
# One line per plugin install (Claude Code + Copilot) plus one per client for personal skills/agents/commands:
# client|plugin|marketplace|marketplace_repo|version|scope|scope_project|enabled|install_ok|source|skills_n|agents_n|commands_n|skills|agents|commands

ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
AIHOOKS_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/plugins.sh"
command -v jq >/dev/null 2>&1 || exit 0

PREFIX="$(printf '%s' "${ORG_PLUGIN_PREFIX:-pc-}" | tr '[:upper:]' '[:lower:]')"
MAX_LIST=4000   # cap for the comma-separated item lists (OTel attribute size)

source_of() {
  [ -z "$1" ] && { printf 'personal'; return; }
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in "$PREFIX"*) printf 'plainconcepts' ;; *) printf 'plugin' ;; esac
}
cap() { if [ "${#1}" -gt "$MAX_LIST" ]; then printf '%s,...' "${1:0:$MAX_LIST}"; else printf '%s' "$1"; fi; }
count() { [ -z "$1" ] && { printf '0'; return; }; printf '%s' "$1" | tr ',' '\n' | grep -c .; }

record() { # record <client> <plugin> <market> <repo> <version> <scope> <scope_project> <enabled> <dir>
  local items s a c
  items="$(plugin_items "$9")"
  s="$(printf '%s\n' "$items" | sed -n 1p)"; a="$(printf '%s\n' "$items" | sed -n 2p)"; c="$(printf '%s\n' "$items" | sed -n 3p)"
  [ "${10:-}" = "skip-empty" ] && [ -z "$s$a$c" ] && return
  local ok=false; [ -n "$9" ] && [ -d "$9" ] && ok=true
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$ok" "$(source_of "$2")" \
    "$(count "$s")" "$(count "$a")" "$(count "$c")" "$(cap "$s")" "$(cap "$a")" "$(cap "$c")"
}

enabled_in() { # enabled_in <settings.json> <id> -> true | false | '' (absent)
  [ -f "$1" ] || return 0
  jq -r --arg id "$2" '(.enabledPlugins // {}) | if has($id) then (.[$id] | tostring) else empty end' "$1" 2>/dev/null
}

CH="$(claude_home)"
MARKETS="$CH/plugins/known_marketplaces.json"

# ---- Claude Code plugins ----
while IFS='|' read -r id plugin market version scope ppath ipath; do
  [ -z "$plugin" ] && continue
  repo=""
  if [ -n "$market" ] && [ -f "$MARKETS" ]; then
    repo="$(jq -r --arg m "$market" '.[$m].source // {} | if (.source == "directory" or .source == "file")
             then "local:" + ((.path // "") | split("/") | last) else (.repo // .url // .path // "") end' "$MARKETS" 2>/dev/null)"
  fi
  enabled="unknown"; sproj=""
  if [ "$scope" = "user" ]; then
    e="$(enabled_in "$CH/settings.json" "$id")"; [ -n "$e" ] && enabled="$e"
  elif [ -n "$ppath" ]; then
    # Folder name only (no git call: this runs on every session start, before the throttle check)
    sproj="${ppath%/}"; sproj="${sproj##*/}"
    if [ "${PROJECT_MODE:-name}" = "hash" ]; then
      sproj="$(short_hash "$(printf '%s' "$sproj" | tr '[:upper:]' '[:lower:]')$(_setting '.identity.salt' 'CHANGE-ME-IT-SALT')")"
    fi
    for f in settings.local.json settings.json; do
      e="$(enabled_in "$ppath/.claude/$f" "$id")"; [ -n "$e" ] && { enabled="$e"; break; }
    done
  fi
  record claude-code "$plugin" "$market" "$repo" "$version" "$scope" "$sproj" "$enabled" "$ipath"
done < <(claude_installs)

# ---- Copilot plugins ----
while IFS='|' read -r id plugin market version scope ppath ipath; do
  [ -z "$plugin" ] && continue
  record copilot "$plugin" "$market" "" "$version" user "" unknown "$ipath"
done < <(copilot_installs)

# ---- Personal (no plugin) ----
record claude-code "" "" "" "" user "" true "$CH" skip-empty
record copilot "" "" "" "" user "" true "$(copilot_home)" skip-empty
exit 0
