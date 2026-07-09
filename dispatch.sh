#!/usr/bin/env bash
# dispatch.sh - single entry point for the Company AI Hooks (macOS/Linux)
# Usage: dispatch.sh <event> <agent>   (JSON payload via stdin)
# Blocks the prompt (exit 2) on a critical finding; warns (exit 0) otherwise.

EVENT="${1:-}"
AGENT="${2:-unknown}"
export AIHOOKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$AIHOOKS_ROOT/lib/common.sh"
source "$AIHOOKS_ROOT/lib/otel.sh"

VERSION="unknown"
[ -f "$AIHOOKS_ROOT/VERSION" ] && VERSION="$(head -n1 "$AIHOOKS_ROOT/VERSION" | tr -d '[:space:]')"

INPUT="$(cat 2>/dev/null || true)"

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

UHASH="$(user_hash)"
BLOCK_EXIT=0   # set to 2 when a prompt is blocked

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

      # ---- Layer 10: prompt policy (block on critical, warn otherwise) ----
      while IFS='|' read -r rule sev evidence; do
        [ -z "$rule" ] && continue
        red="$(redact "$evidence")"
        rank="$(severity_rank "$sev")"
        if [ "$rank" -ge "$threshold" ]; then action="block"; evt="policy_block"; else action="warn"; evt="policy_warning"; fi
        write_log 'security.jsonl' \
          "{\"ts\":\"$ts\",\"event\":\"$evt\",\"agent\":\"$AGENT\",\"rule\":\"$rule\",\"severity\":\"$sev\",\"action\":\"$action\",\"evidence\":\"$(json_escape "$red")\"}"
        otel_send 'pc.ai.policy_warning' "pc.rule=$rule" "pc.severity=$sev" "pc.action=$action" "pc.agent=$AGENT" \
          "pc.evidence=$red" "pc.user_hash=$UHASH" "pc.hooks_version=$VERSION"
        if [ "$action" = "block" ]; then
          [ -n "$block_msgs" ] && block_msgs="$block_msgs; "
          block_msgs="${block_msgs}${rule} (${red})"
        else
          [ -n "$warn_msgs" ] && warn_msgs="$warn_msgs; "
          warn_msgs="${warn_msgs}${rule} (${red})"
        fi
      done < <("$AIHOOKS_ROOT/layers/10-policy/scan-prompt.sh" "$prompt")

      # ---- Layer 30: skills detected in the prompt (namespaced tokens only) ----
      while IFS='|' read -r skill plugin source kind; do
        [ -z "$skill" ] && continue
        otel_send 'pc.ai.skill_usage' "pc.skill=$skill" "pc.plugin=$plugin" "pc.source=$source" "pc.kind=$kind" \
          "pc.agent=$AGENT" "pc.user_hash=$UHASH"
      done < <("$AIHOOKS_ROOT/layers/30-skills/skill-usage.sh" "$prompt" "" "")

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
      local tool name kind
      tool="$(json_field tool_name toolName)"
      name=""; kind=""
      case "$tool" in
        [Ss]kill)
          name="$(printf '%s' "$INPUT" | { command -v jq >/dev/null 2>&1 && jq -r '.tool_input.skill // .toolArgs.skill // .tool_input.name // .tool_input.command // empty' 2>/dev/null || sed -n 's/.*"skill"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; })"
          kind="skill"
          ;;
        [Tt]ask)
          name="$(printf '%s' "$INPUT" | { command -v jq >/dev/null 2>&1 && jq -r '.tool_input.subagent_type // .toolArgs.subagent_type // .tool_input.agent_type // .tool_input.name // empty' 2>/dev/null || sed -n 's/.*"subagent_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; })"
          kind="agent"
          ;;
      esac
      if [ -n "$name" ] && [ -n "$kind" ]; then
        while IFS='|' read -r skill plugin source k; do
          [ -z "$skill" ] && continue
          otel_send 'pc.ai.skill_usage' "pc.skill=$skill" "pc.plugin=$plugin" "pc.source=$source" "pc.kind=$k" \
            "pc.agent=$AGENT" "pc.user_hash=$UHASH"
        done < <("$AIHOOKS_ROOT/layers/30-skills/skill-usage.sh" "" "$name" "$kind")
      fi
      ;;

    SessionEnd|sessionEnd)
      otel_flush_queue
      ;;
  esac
}

if ! main; then
  log_error "$AGENT" "$VERSION" "dispatch failure on event $EVENT" 2>/dev/null || true
  # A hook failure must never block the user's flow.
  BLOCK_EXIT=0
fi
# Exit 2 only when a critical finding blocked the prompt; otherwise 0.
exit "$BLOCK_EXIT"
