#!/usr/bin/env bash
# lib/otel.sh - OTLP/HTTP (logs) sender with a local queue. Requires common.sh loaded first.
# otel.background = true (default) + an endpoint: events are only queued (no network in the hook path) and
# a detached 'dispatch.sh flush' worker sends the queue in batches. Otherwise: synchronous send, queue on failure.
# Queue line = one complete OTLP logRecord JSON (same schema as PowerShell).

OTEL_QUEUED=0          # something was queued by this dispatch (the end-of-dispatch hook starts a worker)
OTEL_WORKER_STARTED=0

_otlp_attrs() { # _otlp_attrs k=v k=v ... -> OTLP attributes JSON array
  local out="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$out" ] && out+=","
    out+="{\"key\":\"$(json_escape "$k")\",\"value\":{\"stringValue\":\"$(json_escape "$v")\"}}"
  done
  printf '[%s]' "$out"
}

_otel_severity() { # _otel_severity <event-name> -> "TEXT NUMBER"
  case "$1" in
    *policy_block*|*hook_issue*) printf 'ERROR 17' ;;
    *policy_warning*)            printf 'WARN 13' ;;
    *)                           printf 'INFO 9' ;;
  esac
}

_otlp_resource() {
  local os host
  case "$(uname -s 2>/dev/null)" in Darwin) os=darwin ;; Linux) os=linux ;; *) os=windows ;; esac
  host="$(hostname 2>/dev/null || printf unknown)"
  _otlp_attrs "service.name=pc-ai-hooks" "service.version=${VERSION:-$(hooks_version)}" "os.type=$os" "host.name=$host"
}

_otlp_payload_file() { # _otlp_payload_file <out-file>  (stdin: logRecord lines)
  {
    printf '{"resourceLogs":[{"resource":{"attributes":%s},"scopeLogs":[{"scope":{"name":"pc-ai-hooks"},"logRecords":[' "$(_otlp_resource)"
    grep -v '^[[:space:]]*$' | paste -sd, -
    printf ']}]}]}'
  } > "$1"
}

otel_record() { # otel_record <event-name> k=v k=v ... -> one OTLP logRecord JSON
  local name="$1"; shift
  local ts_nano sev
  ts_nano="$(($(date +%s) * 1000000000))"
  sev="$(_otel_severity "$name")"
  printf '{"timeUnixNano":"%s","severityText":"%s","severityNumber":%s,"body":{"stringValue":"%s"},"attributes":%s}' \
    "$ts_nano" "${sev% *}" "${sev#* }" "$(json_escape "$name")" "$(_otlp_attrs "$@")"
}

now_ms() { # epoch milliseconds (GNU date), else seconds * 1000
  local n; n="$(date +%s%N 2>/dev/null)"
  case "$n" in *N|'') printf '%s' "$(( $(date +%s) * 1000 ))" ;; *) printf '%s' "$(( n / 1000000 ))" ;; esac
}

otel_background() { # queue-only + detached worker? (needs an endpoint; without one there is nothing to send)
  [ "$OTEL_ENABLED" = "true" ] && [ "$OTEL_BACKGROUND" = "true" ] && [ -n "$OTEL_ENDPOINT" ]
}

otel_header_names() { # configured otel.headers names (values never printed)
  command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ] || return 0
  jq -r '(.otel.headers // {}) | keys[]' "$SETTINGS_FILE" 2>/dev/null
}

otel_post() { # otel_post <payload-file> <timeout-s> -> prints the HTTP status; exit 0 on 2xx
  local cfg status
  # Headers (e.g. Authorization) go through a private curl config file, never the command line (visible in ps).
  cfg="$(umask 077; mktemp "$LOG_DIR/.curl.XXXXXX" 2>/dev/null)" || cfg=""
  if [ -n "$cfg" ]; then
    if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
      jq -r '(.otel.headers // {}) | to_entries[] | select(.value != null and .value != "")
             | "header = \"" + (.key + ": " + (.value | tostring) | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")) + "\""' \
        "$SETTINGS_FILE" > "$cfg" 2>/dev/null
    fi
  fi
  status="$(curl -sS -o /dev/null -w '%{http_code}' -m "$2" -X POST -H 'Content-Type: application/json' \
    ${cfg:+-K "$cfg"} --data-binary @"$1" "${OTEL_ENDPOINT%/}/v1/logs" 2>/dev/null)"
  [ -n "$cfg" ] && rm -f "$cfg"
  printf '%s' "${status:-000}"
  case "$status" in 2??) return 0 ;; *) return 1 ;; esac
}

_add_count() { # _add_count <state-file> <delta>
  local n=0
  [ -f "$1" ] && n="$(tr -dc '0-9' < "$1")"
  printf '%s\n' "$(( ${n:-0} + $2 ))" > "$1"
}

_queue_append() { # stdin: logRecord lines -> bounded queue (telemetry-queue.jsonl -> .1 -> dropped, counted)
  mkdir -p "$LOG_DIR"
  local qpath="$LOG_DIR/telemetry-queue.jsonl" size lost
  if [ -f "$qpath" ]; then
    size=$(wc -c < "$qpath" 2>/dev/null || echo 0)
    if [ "$size" -ge "$(awk -v m="$OTEL_QUEUE_MAX_MB" 'BEGIN { printf "%d", m * 1048576 }')" ]; then
      if [ -f "$qpath.1" ]; then
        lost="$(grep -c . "$qpath.1" 2>/dev/null)"
        [ "${lost:-0}" -gt 0 ] && _add_count "$LOG_DIR/state-dropped.txt" "$lost"
        rm -f "$qpath.1"
      fi
      mv -f "$qpath" "$qpath.1"
    fi
  fi
  grep -v '^[[:space:]]*$' >> "$qpath"
  OTEL_QUEUED=1
}

otel_send_records() { # otel_send_records <record-json>... -> queue (background) or ONE request (sync)
  [ "$OTEL_ENABLED" = "true" ] || return 0
  [ "$#" -gt 0 ] || return 0
  if ! otel_background && [ -n "$OTEL_ENDPOINT" ]; then
    mkdir -p "$LOG_DIR"
    local body; body="$(mktemp "$LOG_DIR/.payload.XXXXXX")"
    printf '%s\n' "$@" | _otlp_payload_file "$body"
    if otel_post "$body" 3 >/dev/null; then rm -f "$body"; return 0; fi
    rm -f "$body"
    # no network or endpoint down -> local queue
  fi
  printf '%s\n' "$@" | _queue_append
}

otel_send() { # otel_send <event-name> k=v k=v ...
  [ "$OTEL_ENABLED" = "true" ] || return 0
  otel_send_records "$(otel_record "$@")"
}

otel_queue_info() { # -> "files records"
  local f files=0 recs=0 n
  for f in "$LOG_DIR"/telemetry-queue.jsonl "$LOG_DIR"/telemetry-queue.jsonl.1 "$LOG_DIR"/telemetry-queue.sending-*.jsonl; do
    [ -f "$f" ] || continue
    files=$((files + 1)); n="$(grep -c . "$f" 2>/dev/null)"; recs=$((recs + ${n:-0}))
  done
  printf '%s %s' "$files" "$recs"
}

_flush_lock() { # one flush at a time; a lock older than 2 minutes is stale (crashed worker)
  local lock="$LOG_DIR/flush.lock.d"
  mkdir "$lock" 2>/dev/null && return 0
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null && return 0
  fi
  return 1
}

# Result of the last otel_flush_queue (also written to state-flush.json)
FLUSH_SENT=0; FLUSH_PENDING=0; FLUSH_STATUS=0; FLUSH_ERROR=""; FLUSH_SKIPPED=""

otel_flush_queue() {
  # Sends the queue in batches of otel.flushBatchSize. A sent batch is gone; on the first failure the rest
  # stays in a telemetry-queue.sending-*.jsonl file that the next flush retries first.
  FLUSH_SENT=0; FLUSH_PENDING=0; FLUSH_STATUS=0; FLUSH_ERROR=""; FLUSH_SKIPPED=""
  [ "$OTEL_ENABLED" = "true" ] && [ -n "$OTEL_ENDPOINT" ] || { FLUSH_SKIPPED="no endpoint"; return 0; }
  [ -d "$LOG_DIR" ] || { FLUSH_SKIPPED="empty"; return 0; }
  _flush_lock || { FLUSH_SKIPPED="locked"; return 0; }
  local qpath="$LOG_DIR/telemetry-queue.jsonl" i=0 src f total s e body failed=0 batch n st now last_ok
  for src in "$qpath.1" "$qpath"; do
    # Atomic move: hooks keep appending to a fresh queue while this batch is sent
    if [ -f "$src" ]; then i=$((i + 1)); mv -f "$src" "$LOG_DIR/telemetry-queue.sending-$(date +%s)-$$-$i.jsonl" 2>/dev/null; fi
  done
  batch="${OTEL_BATCH_SIZE:-200}"; [ "$batch" -ge 1 ] 2>/dev/null || batch=200
  body="$(mktemp "$LOG_DIR/.payload.XXXXXX")"
  for f in $(ls "$LOG_DIR"/telemetry-queue.sending-*.jsonl 2>/dev/null | sort); do
    total="$(grep -c . "$f" 2>/dev/null)"; total="${total:-0}"
    s=1
    while [ "$s" -le "$total" ]; do
      e=$((s + batch - 1))
      grep -v '^[[:space:]]*$' "$f" | sed -n "${s},${e}p" | _otlp_payload_file "$body"
      st="$(otel_post "$body" 10)"; FLUSH_STATUS="$st"
      if [ "${st#2}" = "$st" ]; then
        grep -v '^[[:space:]]*$' "$f" | tail -n +"$s" > "$f.tmp" && mv -f "$f.tmp" "$f"
        FLUSH_PENDING=$((total - s + 1)); FLUSH_ERROR="HTTP $st"; failed=1
        break
      fi
      n=$((e < total ? batch : total - s + 1)); FLUSH_SENT=$((FLUSH_SENT + n))
      s=$((e + 1))
    done
    [ "$failed" = 1 ] && break
    rm -f "$f"
  done

  # Report records lost to queue rotation (once the endpoint is reachable again)
  local dropped_file="$LOG_DIR/state-dropped.txt" dropped
  if [ "$failed" = 0 ] && [ -f "$dropped_file" ]; then
    dropped="$(tr -dc '0-9' < "$dropped_file")"
    if [ "${dropped:-0}" -gt 0 ]; then
      [ "${#COMMON[@]}" -gt 0 ] 2>/dev/null || COMMON=("pc.agent=${AGENT:-unknown}" "pc.hooks_version=${VERSION:-}")
      otel_record 'pc.ai.hook_issue' "pc.error=telemetry queue full: $dropped records dropped" "pc.dropped=$dropped" "${COMMON[@]}" \
        | _otlp_payload_file "$body"
      if otel_post "$body" 10 >/dev/null; then rm -f "$dropped_file"; FLUSH_SENT=$((FLUSH_SENT + 1)); fi
    else
      rm -f "$dropped_file"
    fi
  fi
  rm -f "$body"

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; last_ok=""
  if [ "$failed" = 0 ] || [ "$FLUSH_SENT" -gt 0 ]; then last_ok="$now"
  elif [ -f "$LOG_DIR/state-flush.json" ]; then
    last_ok="$(sed -n 's/.*"lastSuccess":"\([^"]*\)".*/\1/p' "$LOG_DIR/state-flush.json")"
  fi
  printf '{"lastAttempt":"%s","lastSuccess":"%s","lastError":"%s","lastStatus":%s,"lastSent":%s}\n' \
    "$now" "$last_ok" "$(json_escape "$FLUSH_ERROR")" "$((10#${FLUSH_STATUS:-0}))" "$FLUSH_SENT" > "$LOG_DIR/state-flush.json"
  rm -rf "$LOG_DIR/flush.lock.d"
  return 0
}

otel_start_worker() { # otel_start_worker <event> - detached 'dispatch.sh <event>': the hook never waits for the network
  [ "$OTEL_WORKER_STARTED" = 1 ] && return 0
  OTEL_WORKER_STARTED=1
  local launcher=""
  command -v setsid >/dev/null 2>&1 && launcher="setsid"
  [ -z "$launcher" ] && command -v nohup >/dev/null 2>&1 && launcher="nohup"
  ( cd / && $launcher "$AIHOOKS_ROOT/dispatch.sh" "$1" "${AGENT:-unknown}" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

otel_complete_dispatch() {
  # End of every hook run (background mode): start a flush worker when something was queued now,
  # or when an older queue is waiting and the last attempt is older than otel.retryMinutes.
  otel_background || return 0
  [ "$OTEL_WORKER_STARTED" = 1 ] && return 0
  if [ "$OTEL_QUEUED" = 1 ]; then otel_start_worker flush; return 0; fi
  local pending=0 f
  for f in "$LOG_DIR"/telemetry-queue.jsonl "$LOG_DIR"/telemetry-queue.sending-*.jsonl; do [ -f "$f" ] && pending=1; done
  [ "$pending" = 1 ] || return 0
  if [ ! -f "$LOG_DIR/state-flush.json" ] || [ -n "$(find "$LOG_DIR/state-flush.json" -mmin +"${OTEL_RETRY_MINUTES:-5}" 2>/dev/null)" ]; then
    otel_start_worker flush
  fi
}
