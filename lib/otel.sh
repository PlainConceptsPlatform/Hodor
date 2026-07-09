#!/usr/bin/env bash
# lib/otel.sh - OTLP/HTTP (logs) sender with local queue. Requires common.sh loaded first.

_otlp_attrs() { # _otlp_attrs k=v k=v ... -> OTLP attributes JSON array
  local out="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$out" ] && out+=","
    out+="{\"key\":\"$(json_escape "$k")\",\"value\":{\"stringValue\":\"$(json_escape "$v")\"}}"
  done
  printf '[%s]' "$out"
}

_otlp_payload() { # _otlp_payload <logRecords-json>
  printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"pc-ai-hooks"}}]},"scopeLogs":[{"logRecords":[%s]}]}]}' "$1"
}

otel_send() { # otel_send <event-name> k=v k=v ...
  [ "$OTEL_ENABLED" = "true" ] || return 0
  local name="$1"; shift
  local ts_nano attrs record
  ts_nano="$(($(date +%s) * 1000000000))"
  attrs="$(_otlp_attrs "$@")"
  record="{\"timeUnixNano\":\"$ts_nano\",\"severityText\":\"WARN\",\"body\":{\"stringValue\":\"$(json_escape "$name")\"},\"attributes\":$attrs}"

  if [ -n "$OTEL_ENDPOINT" ]; then
    if curl -fsS -m 3 -X POST -H 'Content-Type: application/json' \
        -d "$(_otlp_payload "$record")" "${OTEL_ENDPOINT%/}/v1/logs" >/dev/null 2>&1; then
      return 0
    fi
  fi
  # no endpoint or no network -> local queue
  mkdir -p "$LOG_DIR"
  local qpath="$LOG_DIR/telemetry-queue.jsonl"
  rotate_log "$qpath" "$OTEL_QUEUE_MAX_MB" 2
  printf '%s\n' "$record" >> "$qpath"
}

otel_flush_queue() {
  [ "$OTEL_ENABLED" = "true" ] || return 0
  [ -n "$OTEL_ENDPOINT" ] || return 0
  local qpath="$LOG_DIR/telemetry-queue.jsonl" records
  [ -s "$qpath" ] || return 0
  records="$(paste -sd, "$qpath")"
  if curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
      -d "$(_otlp_payload "$records")" "${OTEL_ENDPOINT%/}/v1/logs" >/dev/null 2>&1; then
    rm -f "$qpath"
  fi
}
