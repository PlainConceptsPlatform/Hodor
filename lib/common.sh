#!/usr/bin/env bash
# lib/common.sh - shared functions (bash). Requires: grep, sed, awk; jq recommended.

AIHOOKS_ROOT="${AIHOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# AIHOOKS_SETTINGS overrides the settings path (used by the test suite for isolation; unset in production).
SETTINGS_FILE="${AIHOOKS_SETTINGS:-$AIHOOKS_ROOT/config/settings.json}"

_setting() { # _setting <jq-path> <default>
  local v key
  if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
    v=$(jq -r "$1 // empty" "$SETTINGS_FILE" 2>/dev/null)
    [ -n "$v" ] && { echo "$v"; return; }
    echo "$2"; return
  fi
  # Fallback without jq: leaf keys are unique in the settings schema, so match by the last path segment.
  if [ -f "$SETTINGS_FILE" ]; then
    key="${1##*.}"
    v="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}[:space:]]+)" "$SETTINGS_FILE" 2>/dev/null \
         | head -n1 | sed -E "s/.*:[[:space:]]*//; s/^\"//; s/\"$//")"
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
IDENTITY_MODE="$(_setting '.identity.mode' 'hash')"            # hash | email (email also sends pc.user)
PROJECT_MODE="$(_setting '.telemetry.projectMode' 'name')"     # name | hash
DEDUPE_SECONDS="$(_setting '.telemetry.dedupeSeconds' 120)"     # same skill, same session, within N s = 1 use (0 = off)
TRACK_FILE_READS="$(_setting '.usage.trackFileReads' false)"   # heuristic: skills/agents loaded by reading their .md (Claude; always on for Copilot)
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
  # 'enabled' is not a unique leaf key, so the no-jq fallback cannot read it (inventory needs jq anyway)
  INVENTORY_ENABLED="$(jq -r 'if .inventory.enabled == false then "false" else "true" end' "$SETTINGS_FILE" 2>/dev/null)"
else
  INVENTORY_ENABLED="true"
fi
INVENTORY_INTERVAL_HOURS="$(_setting '.inventory.intervalHours' 24)"
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
  # jq's '//' treats false as missing, so read the boolean explicitly
  OTEL_BACKGROUND="$(jq -r 'if .otel.background == false then "false" else "true" end' "$SETTINGS_FILE" 2>/dev/null)"
else
  OTEL_BACKGROUND="$(_setting '.otel.background' true)"   # queue only + detached flush worker
fi
OTEL_BATCH_SIZE="$(_setting '.otel.flushBatchSize' 200)"       # records per OTLP request when flushing the queue
OTEL_RETRY_MINUTES="$(_setting '.otel.retryMinutes' 5)"        # an idle queue is retried at most every N minutes

severity_rank() { # severity_rank <severity> -> numeric rank
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    critical) echo 3 ;;
    high)     echo 2 ;;
    medium)   echo 1 ;;
    none)     echo 99 ;; # threshold 'none' = warn-only (nothing reaches it)
    *)        echo 0 ;;
  esac
}

hooks_version() { # full version identity: build-info.json -> live git -> fallback
  local root bi base commit count sha version
  root="$AIHOOKS_ROOT"
  bi="$root/build-info.json"
  if [ -f "$bi" ]; then
    if command -v jq >/dev/null 2>&1; then
      version="$(jq -r '.version // empty' "$bi" 2>/dev/null)"
    else
      version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$bi" | head -n1)"
    fi
    [ -n "$version" ] && { printf '%s' "$version"; return; }
  fi
  base="0.0"
  [ -f "$root/VERSION" ] && base="$(head -n1 "$root/VERSION" | tr -d '[:space:]')"
  commit="unknown"; count=0
  if command -v git >/dev/null 2>&1; then
    sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)"
    if [ -n "$sha" ]; then commit="$sha"; count="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"; fi
  fi
  if [ "$commit" = "unknown" ]; then printf '%s' "$base.0+gunknown"; else printf '%s' "$base.$count+g$commit"; fi
}

redact() { # redact <text>
  local t="$1"
  if [ "${#t}" -le 12 ]; then echo '[REDACTED]'; else echo "${t:0:4}...${t: -4}"; fi
}

short_hash() { # short_hash <text> -> first 16 hex chars of sha256
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  fi
}

user_hash() {
  local email salt
  email="$(_setting '.identity.email' '')"
  [ -z "$email" ] && email="${USER:-unknown}@local"
  salt="$(_setting '.identity.salt' 'CHANGE-ME-IT-SALT')"
  short_hash "${email}${salt}"
}

user_email() { # clear-text identity (identity.mode = email): settings -> git user.email -> USER@local
  local email
  email="$(_setting '.identity.email' '')"
  [ -z "$email" ] && email="$(git config --global user.email 2>/dev/null)"
  [ -z "$email" ] && email="${USER:-unknown}@local"
  printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

repo_name() { # repo_name <git-url> -> org/repo (GitHub) or project/repo (Azure DevOps)
  local u="${1%.git}"
  u="$(printf '%s' "$u" | sed -E 's#^[^@/]+@([^:/]+):#\1/#')"
  printf '%s' "$u" | tr '\\' '/' | tr '/' '\n' | grep -v -e '^$' -e '^_git$' | tail -n 2 | paste -sd/ -
}

project_name() { # project_name <cwd> -> git origin -> folder name -> unknown (hashed if projectMode=hash)
  local cwd="${1:-$PWD}" name="" url
  if [ -d "$cwd" ]; then
    url="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
    [ -n "$url" ] && name="$(repo_name "$url")"
  fi
  if [ -z "$name" ]; then
    cwd="$(printf '%s' "$cwd" | tr '\\' '/')"; cwd="${cwd%/}"
    name="${cwd##*/}"
  fi
  [ -z "$name" ] && { printf 'unknown'; return; }
  if [ "$PROJECT_MODE" = "hash" ]; then
    short_hash "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')$(_setting '.identity.salt' 'CHANGE-ME-IT-SALT')"
  else
    printf '%s' "$name"
  fi
}

usage_duplicate() { # usage_duplicate <key> -> exit 0 if already counted within DEDUPE_SECONDS (else records it)
  local key now path tmp ts k dup=1
  [ "${DEDUPE_SECONDS:-0}" -gt 0 ] 2>/dev/null || return 1
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
  now="$(date +%s)"
  mkdir -p "$LOG_DIR"
  path="$LOG_DIR/state-dedupe.txt"; tmp="$path.$$"
  : > "$tmp"
  if [ -f "$path" ]; then
    while read -r ts k; do
      [ -z "$k" ] && continue
      [ $((now - ts)) -lt "$DEDUPE_SECONDS" ] || continue
      printf '%s %s\n' "$ts" "$k" >> "$tmp"
      [ "$k" = "$key" ] && dup=0
    done < "$path"
  fi
  [ "$dup" -ne 0 ] && printf '%s %s\n' "$now" "$key" >> "$tmp"
  mv -f "$tmp" "$path"
  return "$dup"
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
