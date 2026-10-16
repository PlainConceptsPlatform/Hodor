#!/usr/bin/env bash
# dispatch.sh - single entry point for the Company AI Hooks (macOS/Linux)
# Usage: dispatch.sh <event> <agent>   (JSON payload via stdin)
# Blocks the prompt (exit 2) on a critical finding; warns (exit 0) otherwise.

EVENT="${1:-}"
AGENT="${2:-unknown}"
export AIHOOKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$AIHOOKS_ROOT/lib/common.sh"
source "$AIHOOKS_ROOT/lib/otel.sh"

VERSION="$(hooks_version)"

# 'version' is a diagnostic command: answer and exit BEFORE reading stdin (which would block).
if [ "$EVENT" = "version" ]; then
  bi="$AIHOOKS_ROOT/build-info.json"
  commit="unknown"; count=0; bdate=""
  if [ -f "$bi" ] && command -v jq >/dev/null 2>&1; then
    commit="$(jq -r '.commit // "unknown"' "$bi" 2>/dev/null)"
    count="$(jq -r '.commitCount // 0' "$bi" 2>/dev/null)"
    bdate="$(jq -r '.buildDate // ""' "$bi" 2>/dev/null)"
  fi
  printf '{"name":"hodor","version":"%s","commit":"%s","commitCount":%s,"buildDate":"%s","root":"%s"}\n' \
    "$(json_escape "$VERSION")" "$(json_escape "$commit")" "${count:-0}" "$(json_escape "$bdate")" "$(json_escape "$AIHOOKS_ROOT")"
  exit 0
fi

# Worker / diagnostic events take no stdin payload (a detached worker has no stdin to read).
case "$EVENT" in
  inventory)
    # Background SessionStart: the hook saved its payload for this worker
    INPUT="$(cat "$LOG_DIR/pending-inventory.json" 2>/dev/null)"; rm -f "$LOG_DIR/pending-inventory.json" ;;
  flush|selftest) INPUT="" ;;
  *) INPUT="$(cat 2>/dev/null || true)" ;;
esac

json_field() { # json_field <field...> - first non-empty field from the payload
  local f v
  for f in "$@"; do
    if command -v jq >/dev/null 2>&1; then
      v="$(printf '%s' "$INPUT" | jq -r ".$f // empty" 2>/dev/null)"
    else
      v="$(printf '%s' "$INPUT" | sed -n "s/.*\"$f\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1)"
    fi
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}

TOOL_IN=""    # tool input JSON of one batched call (toolCalls[].args); empty = read it from the payload
tool_arg() { # tool_arg <field...> - first non-empty field of the tool input (object, or JSON string as Copilot CLI sends it)
  local f v
  for f in "$@"; do
    if command -v jq >/dev/null 2>&1; then
      if [ -n "$TOOL_IN" ]; then
        v="$(printf '%s' "$TOOL_IN" | jq -r --arg f "$f" '.[$f] // empty | tostring' 2>/dev/null)"
      else
        v="$(printf '%s' "$INPUT" | jq -r --arg f "$f" '(.tool_input // .toolInput // .toolArgs // .tool_args // {})
              | (if type == "string" then (fromjson? // {}) else . end) | .[$f] // empty | tostring' 2>/dev/null)"
      fi
    else
      v="$(printf '%s' "${TOOL_IN:-$INPUT}" | sed -n "s/.*\"$f\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1)"
    fi
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}

BLOCK_EXIT=0   # set to 2 when a prompt is blocked
CWD="$(json_field cwd workspaceFolder workspace_folder)"
SID="$(json_field session_id sessionId conversation_id conversationId)"
export ORG_PLUGIN_PREFIX PROJECT_MODE

# Shared who/where attributes, computed once and only when something is emitted (project = git call).
COMMON=(); COMMON_READY=0
common_attrs() {
  [ "$COMMON_READY" = 1 ] && return
  local account; account="$(client_account "$AGENT")"
  COMMON=("pc.agent=$AGENT" "pc.user=$(user_email)" "pc.account=${account#*|}" "pc.account_type=${account%%|*}" "pc.hooks_version=$VERSION" \
    "pc.folder=$(folder_name "$CWD")" "pc.project=$(project_name "$CWD")")
  [ -n "$SID" ] && COMMON+=("pc.session_id=$SID")
  COMMON_READY=1
}

send_usage() { # stdin: usage.sh lines -> one batched request; same skill+session inside the dedupe window is dropped
  local skill plugin source kind via ver market raw records=()
  common_attrs
  while IFS='|' read -r skill plugin source kind via ver market raw; do
    [ -z "$skill" ] && continue
    usage_duplicate "${SID:-nosession}|$plugin|$skill" && continue
    records+=("$(otel_record 'pc.ai.skill_usage' "pc.skill=$skill" "pc.skill_raw=${raw:-$skill}" "pc.plugin=$plugin" "pc.source=$source" "pc.kind=$kind" \
      "pc.via=$via" "pc.plugin_version=$ver" "pc.marketplace=$market" "${COMMON[@]}")")
  done
  otel_send_records "${records[@]}"
}

send_inventory() { # ---- Inventory layer: what this user has installed (throttled: interval or fingerprint change) ----
  [ "$INVENTORY_ENABLED" = "true" ] || return 0
  local inv fp state now sent prev due snapshot size records=() line
  inv="$("$AIHOOKS_ROOT/layers/inventory/inventory.sh")"
  [ -n "$inv" ] || return 0
  fp="$(short_hash "$inv")"
  state="$LOG_DIR/state-inventory.txt"
  now="$(date +%s)"; sent=0; prev=""
  [ -f "$state" ] && read -r sent prev < "$state"
  due=0
  if [ "$prev" != "$fp" ] || [ $((now - ${sent:-0})) -ge $(( ${INVENTORY_INTERVAL_HOURS%.*} * 3600 )) ]; then due=1; fi
  [ "$due" = 1 ] || return 0
  common_attrs
  snapshot="$(short_hash "$now$$$RANDOM" | cut -c1-12)"
  size="$(printf '%s\n' "$inv" | grep -c .)"
  while IFS='|' read -r client plugin market repo version scope sproj enabled iok source sn an cn skills agents commands; do
    [ -z "$client" ] && continue
    records+=("$(otel_record 'pc.ai.inventory' "pc.client=$client" "pc.plugin=$plugin" "pc.marketplace=$market" \
      "pc.marketplace_repo=$repo" "pc.plugin_version=$version" "pc.scope=$scope" "pc.scope_project=$sproj" \
      "pc.enabled=$enabled" "pc.install_ok=$iok" "pc.source=$source" "pc.skills_count=$sn" "pc.agents_count=$an" "pc.commands_count=$cn" \
      "pc.skills=$skills" "pc.agents=$agents" "pc.commands=$commands" \
      "pc.inventory_id=$snapshot" "pc.inventory_size=$size" "${COMMON[@]}")")
  done <<< "$inv"
  otel_send_records "${records[@]}"
  mkdir -p "$LOG_DIR"; printf '%s %s\n' "$now" "$fp" > "$state"
}

# Optional raw-payload capture for troubleshooting (only when HODOR_DEBUG is set).
if [ -n "${HODOR_DEBUG:-}" ] && [ -n "$INPUT" ]; then
  write_log 'payloads-debug.jsonl' \
    "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"$(json_escape "$EVENT")\",\"agent\":\"$(json_escape "$AGENT")\",\"raw\":\"$(json_escape "$INPUT")\"}"
fi

main() {
  case "$EVENT" in

    UserPromptSubmit|userPromptSubmitted)
      local prompt block_msgs="" warn_msgs="" ts logp threshold rank red action evt reason warning
      prompt="$(json_field prompt userMessage user_message)"
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      threshold="$(severity_rank "$POLICY_BLOCK_SEVERITY")"

      # ---- Policy layer: prompt policy (block on critical, warn otherwise) ----
      while IFS='|' read -r rule sev evidence; do
        [ -z "$rule" ] && continue
        red="$(redact "$evidence")"
        rank="$(severity_rank "$sev")"
        if [ "$rank" -ge "$threshold" ]; then action="block"; evt="policy_block"; else action="warn"; evt="policy_warning"; fi
        write_log 'security.jsonl' \
          "{\"ts\":\"$ts\",\"event\":\"$evt\",\"agent\":\"$AGENT\",\"rule\":\"$rule\",\"severity\":\"$sev\",\"action\":\"$action\",\"evidence\":\"$(json_escape "$red")\",\"version\":\"$(json_escape "$VERSION")\"}"
        common_attrs
        otel_send "pc.ai.policy_$( [ "$action" = block ] && echo block || echo warning )" "pc.rule=$rule" "pc.severity=$sev" "pc.action=$action" \
          "pc.evidence=$red" "${COMMON[@]}"
        if [ "$action" = "block" ]; then
          [ -n "$block_msgs" ] && block_msgs="$block_msgs; "
          block_msgs="${block_msgs}${rule} (${red})"
        else
          [ -n "$warn_msgs" ] && warn_msgs="$warn_msgs; "
          warn_msgs="${warn_msgs}${rule} (${red})"
        fi
      done < <("$AIHOOKS_ROOT/layers/policy/scan-prompt.sh" "$prompt")

      # ---- Usage layer: /plugin:name tokens, or a bare /name at the start when installed ----
      "$AIHOOKS_ROOT/layers/usage/usage.sh" "$prompt" "" "" "" "$CWD" "$AGENT" | send_usage

      logp="$LOG_DIR/security.jsonl"
      if [ -n "$block_msgs" ]; then
        # BLOCK: stop the prompt before it reaches the model.
        reason="[Plain Concepts AI policy BLOCK] Your prompt was blocked before reaching the model: possible ${block_msgs}. Remove the sensitive data and try again. Details: ${logp} | Questions or false positives: ${SUPPORT_CHANNEL}"
        printf '%s\n' "$reason" >&2
        printf '{"decision":"block","reason":"%s"}\n' "$(json_escape "$reason")"
        BLOCK_EXIT=2
      elif [ -n "$warn_msgs" ]; then
        # WARN (non-blocking): request continues.
        warning="[Plain Concepts AI policy WARNING] This prompt does not comply with the company AI policy: ${warn_msgs}. The request continues, but please review what you are sharing with the model. Details: ${logp} | Questions or false positives: ${SUPPORT_CHANNEL}"
        printf '{"systemMessage":"%s"}\n' "$(json_escape "$warning")"
      fi
      ;;

    PreToolUse|preToolUse)
      local tool name track_reads=false
      # File-read heuristic: opt-in on Claude (needs an extra Read|Bash matcher); free on Copilot, whose
      # preToolUse already runs for every tool call.
      { [ "$TRACK_FILE_READS" = "true" ] || [ "$AGENT" = "copilot" ]; } && track_reads=true
      handle_tool() { # handle_tool <tool name> - usage.sh lines for one call (its input: TOOL_IN, or the payload)
        local name text
        case "$1" in
          [Ss]kill)
            name="$(tool_arg skill name command)"
            [ -n "$name" ] && "$AIHOOKS_ROOT/layers/usage/usage.sh" "" "$name" skill "" "$CWD" "$AGENT"
            ;;
          [Tt]ask|[Aa]gent)
            name="$(tool_arg subagent_type subagentType agent_type agentType name)"
            [ -n "$name" ] && "$AIHOOKS_ROOT/layers/usage/usage.sh" "" "$name" agent "" "$CWD" "$AGENT"
            ;;
          Read|read|view|Bash|bash|shell|powershell|PowerShell)
            # Heuristic: a skill/agent/command loaded by reading its .md instead of being invoked
            if [ "$track_reads" = true ]; then
              text="$(tool_arg file_path filePath path command)"
              [ -n "$text" ] && "$AIHOOKS_ROOT/layers/usage/usage.sh" "" "" "" "$text" "$CWD" "$AGENT"
            fi
            ;;
        esac
        return 0
      }
      tool="$(json_field tool_name toolName)"
      if [ -n "$tool" ]; then
        handle_tool "$tool" | send_usage
      elif command -v jq >/dev/null 2>&1; then
        # Batch as the Copilot CLI agents window sends it: toolCalls[{name, args}] -> two lines per call (name, args JSON)
        while IFS= read -r name && IFS= read -r TOOL_IN; do
          [ -n "$name" ] && handle_tool "$name"
        done < <(printf '%s' "$INPUT" | jq -r '(.toolCalls // .tool_calls // [])[]
                   | (.name // .toolName // ""),
                     ((.args // .arguments // .input // {}) | (if type == "string" then (fromjson? // {}) else . end) | tojson)' 2>/dev/null) \
          | send_usage
        TOOL_IN=""
      elif [ "$track_reads" = true ]; then
        # No jq: scan the whole batch for skill/agent/command .md paths (Skill/Task names in a batch need jq)
        "$AIHOOKS_ROOT/layers/usage/usage.sh" "" "" "" "$INPUT" "$CWD" "$AGENT" | send_usage
      fi
      ;;

    SessionStart|sessionStart)
      if otel_background; then
        # Inventory scan + queue retry run in a detached worker; the session starts right away.
        if [ "$INVENTORY_ENABLED" = "true" ] && [ -n "$INPUT" ]; then
          mkdir -p "$LOG_DIR"; printf '%s' "$INPUT" > "$LOG_DIR/pending-inventory.json"
        fi
        otel_start_worker inventory
      else
        # Opportunistic retry of anything queued while offline, then the inventory
        otel_flush_queue
        send_inventory
      fi
      ;;

    inventory)
      # Background worker started by SessionStart
      OTEL_WORKER_STARTED=1
      send_inventory
      otel_flush_queue
      ;;

    SessionEnd|sessionEnd)
      if otel_background; then otel_start_worker flush; else otel_flush_queue; fi
      ;;

    flush)
      # Background worker (or manual: dispatch.sh flush)
      OTEL_WORKER_STARTED=1
      otel_flush_queue
      printf '{"ok":%s,"sent":%s,"pending":%s,"status":%s,"error":"%s","skipped":"%s"}\n' \
        "$([ -z "$FLUSH_ERROR" ] && echo true || echo false)" "$FLUSH_SENT" "$FLUSH_PENDING" "$((10#${FLUSH_STATUS:-0}))" \
        "$(json_escape "$FLUSH_ERROR")" "$FLUSH_SKIPPED"
      ;;

    selftest)
      # Synchronous end-to-end check: one pc.ai.selftest record straight to the endpoint
      OTEL_WORKER_STARTED=1
      local ok=false status=0 err="" ms=0 t0 t1 body q hdrs flush_state
      if [ "$OTEL_ENABLED" != "true" ]; then err="otel.enabled = false"
      elif [ -z "$OTEL_ENDPOINT" ]; then err="otel.endpoint is empty"
      else
        common_attrs
        mkdir -p "$LOG_DIR"; body="$(mktemp "$LOG_DIR/.payload.XXXXXX")"
        otel_record 'pc.ai.selftest' "pc.selftest=true" "${COMMON[@]}" | _otlp_payload_file "$body"
        t0="$(now_ms)"
        status="$(otel_post "$body" 5)" && ok=true
        t1="$(now_ms)"; ms=$((t1 - t0))
        rm -f "$body"
        [ "$ok" = true ] || err="HTTP $status"
      fi
      q="$(otel_queue_info)"
      hdrs="$(otel_header_names | sed 's/.*/"&"/' | paste -sd, -)"
      flush_state=""; [ -f "$LOG_DIR/state-flush.json" ] && flush_state="$(tr -d '\n\r' < "$LOG_DIR/state-flush.json")"
      printf '{"ok":%s,"endpoint":"%s","headers":[%s],"status":%s,"ms":%s,"error":"%s","background":%s,"queue":{"files":%s,"records":%s},"flush":%s,"version":"%s"}\n' \
        "$ok" "$(json_escape "$OTEL_ENDPOINT")" "$hdrs" "$((10#${status:-0}))" "$ms" "$(json_escape "$err")" \
        "$(otel_background && echo true || echo false)" "${q% *}" "${q#* }" "${flush_state:-null}" "$(json_escape "$VERSION")"
      [ "$ok" = true ] || BLOCK_EXIT=1
      ;;
  esac
  return 0
}

if ! main; then
  log_error "$AGENT" "$VERSION" "dispatch failure on event $EVENT" 2>/dev/null || true
  # A hook failure must never block the user's flow.
  BLOCK_EXIT=0
fi
# Background mode: hand anything queued to a detached flush worker (never waits for the network).
otel_complete_dispatch 2>/dev/null || true
# Exit 2 only when a critical finding blocked the prompt; otherwise 0.
exit "$BLOCK_EXIT"
