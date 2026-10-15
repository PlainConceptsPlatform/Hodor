#!/usr/bin/env bash
# layers/usage/usage.sh - detects skill/agent/command usage, classified by plugin namespace
# Usage: usage.sh "<prompt>" "<direct-name>" "<kind: skill|agent>" ["<file-text>"] ["<cwd>"] ["<client>"]
# Output: one line per event -> SKILL|PLUGIN|SOURCE|KIND|VIA|VERSION|MARKETPLACE|RAW
#   skill: canonical name (agents: frontmatter name, the same for Claude Code and Copilot); raw: name as invoked
#   source: plainconcepts (plugin starts with org prefix) | plugin (other namespaced) | personal (no namespace)
#   kind:   skill | agent | command (command = a commands/*.md file of the plugin or personal folder)
#   via:    tool (Skill/Agent tool) | prompt (/name typed by the user) | file_read (the .md was read directly)
# Prompt: /plugin:name tokens anywhere, plus a bare /name at the very start only when it is installed locally
# (built-ins like /clear and paths like /usr/bin never match). File text: a Read path or a Bash command.

PROMPT="$1"
DIRECT_NAME="$2"
DIRECT_KIND="${3:-skill}"
FILE_TEXT="${4:-}"
CWD="${5:-}"
CLIENT="${6:-}"
ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$ROOT/lib/plugins.sh"

PREFIX="${ORG_PLUGIN_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  PREFIX="pc-"
  settings="${AIHOOKS_SETTINGS:-$ROOT/config/settings.json}"
  if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
    v="$(jq -r '.skills.orgPluginPrefix // empty' "$settings" 2>/dev/null)"
    [ -n "$v" ] && PREFIX="$v"
  fi
fi
LOWER_PREFIX="$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')"

emit() { # emit <plugin> <bare> <kind> <via> <require-found 0|1>
  local plugin="$1" bare="$2" kind="$3" via="$4" req="$5" res r_plugin r_kind r_ver r_market r_found r_name source
  [ -z "$bare" ] && return
  res="$(resolve_item "$plugin" "$bare" "$kind" "$CWD" "$CLIENT")"
  IFS='|' read -r r_plugin r_kind r_ver r_market r_found r_name <<< "$res"
  [ "$req" = "1" ] && [ "$r_found" != "1" ] && return
  if [ -n "$r_plugin" ]; then
    case "$(printf '%s' "$r_plugin" | tr '[:upper:]' '[:lower:]')" in
      "$LOWER_PREFIX"*) source="plainconcepts" ;;
      *)                source="plugin" ;;
    esac
  else
    source="personal"
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${r_name:-$bare}" "$r_plugin" "$source" "${r_kind:-$kind}" "$via" "$r_ver" "$r_market" \
    "${plugin:+$plugin:}$bare"
}

SEEN=""
emit_once() { # emit_once <plugin> <bare> <kind> <via> <require-found>
  local key
  [ -z "$2" ] && return
  key="$(printf '%s:%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')"
  case " $SEEN " in *" $key "*) return ;; esac
  SEEN="$SEEN $key"
  emit "$@"
}

split_emit() { # split_emit <name> <kind> <via> <require-found> - "plugin:rest" or bare
  case "$1" in
    *:*) emit_once "${1%%:*}" "${1#*:}" "$2" "$3" "$4" ;;
    *)   emit_once "" "$1" "$2" "$3" "$4" ;;
  esac
}

[ -n "$DIRECT_NAME" ] && split_emit "$DIRECT_NAME" "$DIRECT_KIND" tool 0

if [ -n "$PROMPT" ]; then
  # Namespaced tokens (/plugin:name, /plugin:group:name) are reliable invocations without a catalog.
  while IFS= read -r tok; do
    tok="$(printf '%s' "$tok" | sed 's|^[[:space:]]*/||')"
    [ -n "$tok" ] && split_emit "$tok" skill prompt 0
  done < <(printf '%s' "$PROMPT" | grep -oE '(^|[[:space:]])/[A-Za-z0-9][A-Za-z0-9._-]{0,63}(:[A-Za-z0-9][A-Za-z0-9._-]{0,63})+' 2>/dev/null)
  # A bare /name counts only at the start of the prompt AND when it is installed locally.
  bare="$(printf '%s' "$PROMPT" | head -n1 | sed -nE 's#^[[:space:]]*/([A-Za-z0-9][A-Za-z0-9._-]{0,63})([[:space:]].*)?$#\1#p')"
  [ -n "$bare" ] && emit_once "" "$bare" command prompt 1
fi

if [ -n "$FILE_TEXT" ]; then
  text="$(printf '%s' "$FILE_TEXT" | tr '\\' '/')"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    case "$m" in
      */SKILL.md|*/skill.md) kind="skill"; prefix="${m%/skills/*}"; bare="${m##*/skills/}"; bare="${bare%/*}" ;;
      *agents/*)             kind="agent"; prefix="${m%/agents/*}"; bare="${m##*/agents/}"; bare="${bare%.md}"; bare="${bare%.agent}" ;;
      *)                     kind="command"; prefix="${m%/commands/*}"; bare="${m##*/commands/}"; bare="$(printf '%s' "${bare%.md}" | tr '/' ':')" ;;
    esac
    [ "$prefix" = "$m" ] && prefix=""
    # Plugin = the folder holding skills/agents/commands, skipping a version folder (cache: <plugin>/<version>/skills/...)
    plugin=""
    while [ -n "$prefix" ]; do
      seg="${prefix##*/}"
      if printf '%s' "$seg" | grep -qiE '^(v?[0-9]+(\.[0-9]+)*([-+].*)?|[0-9a-f]{7,40}|unknown)$'; then
        case "$prefix" in */*) prefix="${prefix%/*}" ;; *) prefix="" ;; esac
        continue
      fi
      plugin="$seg"; break
    done
    case "$plugin" in .claude|.copilot|.github) plugin="" ;; esac
    if [ "$kind" != "command" ] && [ -f "$m" ]; then
      fm="$(frontmatter_name "$m")"; [ -n "$fm" ] && bare="$fm"
    fi
    emit_once "$plugin" "$bare" "$kind" file_read 0
  done < <(printf '%s' "$text" | grep -oiE '/?([^/[:space:]"<>|'\'']+/)*(skills/[^/[:space:]"<>|'\'']+/SKILL\.md|agents/[^/[:space:]"<>|'\'']+\.md|commands/[^[:space:]"<>|'\'']+\.md)' 2>/dev/null)
fi
exit 0
