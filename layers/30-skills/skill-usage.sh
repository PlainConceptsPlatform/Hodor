#!/usr/bin/env bash
# layers/30-skills/skill-usage.sh - detects skill/agent usage, classified by plugin namespace
# Usage: skill-usage.sh "<prompt>" "<direct-name>" "<kind: skill|agent>"
# Output: one line per event -> SKILL|PLUGIN|SOURCE|KIND
#   source: plainconcepts (plugin starts with org prefix) | plugin (other namespaced) | personal (no namespace)
# The prompt is scanned ONLY for namespaced /plugin:skill tokens (bare /word tokens are ignored).

PROMPT="$1"
DIRECT_NAME="$2"
DIRECT_KIND="${3:-skill}"
ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PREFIX="pc-"
if command -v jq >/dev/null 2>&1 && [ -f "$ROOT/config/settings.json" ]; then
  v="$(jq -r '.skills.orgPluginPrefix // empty' "$ROOT/config/settings.json" 2>/dev/null)"
  [ -n "$v" ] && PREFIX="$v"
fi

emit() { # emit <name> <kind>
  local name="$1" kind="$2" plugin="" bare="$1" source lower_plugin lower_prefix
  case "$name" in
    *:*)
      plugin="${name%%:*}"
      bare="${name#*:}"
      ;;
  esac
  if [ -n "$plugin" ]; then
    lower_plugin="$(printf '%s' "$plugin" | tr '[:upper:]' '[:lower:]')"
    lower_prefix="$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')"
    case "$lower_plugin" in
      "$lower_prefix"*) source="plainconcepts" ;;
      *)                source="plugin" ;;
    esac
  else
    source="personal"
  fi
  printf '%s|%s|%s|%s\n' "$bare" "$plugin" "$source" "$kind"
}

SEEN=""
emit_once() { # emit_once <name> <kind>
  local lower
  [ -z "$1" ] && return
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case " $SEEN " in *" $lower "*) return ;; esac
  SEEN="$SEEN $lower"
  emit "$1" "$2"
}

[ -n "$DIRECT_NAME" ] && emit_once "$DIRECT_NAME" "$DIRECT_KIND"

if [ -n "$PROMPT" ]; then
  # Only namespaced tokens (/plugin:skill) are reliable skill invocations without a catalog.
  while IFS= read -r tok; do
    tok="$(printf '%s' "$tok" | sed 's|^[[:space:]]*/||')"
    [ -n "$tok" ] && emit_once "$tok" "skill"
  done < <(printf '%s' "$PROMPT" | grep -oE '(^|[[:space:]])/[A-Za-z0-9][A-Za-z0-9._-]{0,63}:[A-Za-z0-9][A-Za-z0-9._-]{0,63}' 2>/dev/null)
fi
exit 0
