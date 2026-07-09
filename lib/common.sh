#!/usr/bin/env bash
# lib/common.sh - shared functions (bash). Requires: grep, sed, awk; jq recommended.

AIHOOKS_ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SETTINGS_FILE="$AIHOOKS_ROOT/config/settings.json"

_setting() { # _setting <jq-path> <default>
  if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
    local v
    v=$(jq -r "$1 // empty" "$SETTINGS_FILE" 2>/dev/null)
    [ -n "$v" ] && { echo "$v"; return; }
  fi
  echo "$2"
}

LOG_DIR="$(_setting '.log.dir' '')"
[ -z "$LOG_DIR" ] && LOG_DIR="${HOME}/.local/state/plainconcepts/ai-hooks"
LOG_MAX_MB="$(_setting '.log.maxSizeMB' 5)"
LOG_MAX_FILES="$(_setting '.log.maxFiles' 3)"
OTEL_ENABLED="$(_setting '.otel.enabled' true)"
OTEL_ENDPOINT="$(_setting '.otel.endpoint' '')"
OTEL_QUEUE_MAX_MB="$(_setting '.otel.queueMaxSizeMB' 2)"
SUPPORT_CHANNEL="$(_setting '.support.channel' '#ai-hooks (Teams)')"
POLICY_BLOCK_SEVERITY="$(_setting '.policy.blockSeverity' 'critical')"
ORG_PLUGIN_PREFIX="$(_setting '.skills.orgPluginPrefix' 'pc-')"

severity_rank() { # severity_rank <severity> -> numeric rank
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    critical) echo 3 ;;
    high)     echo 2 ;;
    medium)   echo 1 ;;
    none)     echo 99 ;; # threshold 'none' = warn-only (nothing reaches it)
    *)        echo 0 ;;
  esac
}

redact() { # redact <text>
  local t="$1"
  if [ "${#t}" -le 12 ]; then echo '[REDACTED]'; else echo "${t:0:4}...${t: -4}"; fi
}

user_hash() {
  local email salt raw
  email="$(_setting '.identity.email' '')"
  [ -z "$email" ] && email="${USER:-unknown}@local"
  salt="$(_setting '.identity.salt' 'CHANGE-ME-IT-SALT')"
  raw="${email}${salt}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$raw" | sha256sum | cut -c1-16
  else
    printf '%s' "$raw" | shasum -a 256 | cut -c1-16
  fi
}

rotate_log() { # rotate_log <file> <max_mb> <max_files>
  local path="$1" max_mb="${2:-5}" max_files="${3:-3}" size i
  [ -f "$path" ] || return 0
  size=$(wc -c < "$path" 2>/dev/null || echo 0)
  [ "$size" -lt $((max_mb * 1024 * 1024)) ] && return 0
  rm -f "${path}.$((max_files - 1))" 2>/dev/null
  for ((i = max_files - 2; i >= 1; i--)); do
    [ -f "${path}.${i}" ] && mv -f "${path}.${i}" "${path}.$((i + 1))"
  done
  mv -f "$path" "${path}.1"
}

write_log() { # write_log <file> <json-line>
  mkdir -p "$LOG_DIR"
  local path="$LOG_DIR/$1"
  rotate_log "$path" "$LOG_MAX_MB" "$LOG_MAX_FILES"
  printf '%s\n' "$2" >> "$path"
}

json_escape() { # json_escape <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

log_error() { # log_error <agent> <version> <message>
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  write_log 'hooks-error.jsonl' \
    "{\"ts\":\"$ts\",\"event\":\"hook_issue\",\"agent\":\"$(json_escape "$1")\",\"version\":\"$(json_escape "$2")\",\"error\":\"$(json_escape "$3")\"}"
  otel_send 'pc.ai.hook_issue' "pc.agent=$1" "pc.hooks_version=$2" "pc.error=$3"
}
