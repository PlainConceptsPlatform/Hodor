#!/usr/bin/env bash
# tests/run.sh - dependency-free regression suite (bash side).
# Runs the shared contract fixtures (tests/cases/*) against dispatch.sh in isolation
# (temp log dir + temp settings via AIHOOKS_SETTINGS), plus direct unit checks.
# Exit code 1 if any check fails.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DISPATCH="$ROOT/dispatch.sh"
CASES="$HERE/cases"

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t hodor)"
LOGDIR="$WORK/logs"; mkdir -p "$LOGDIR"
SETTINGS="$WORK/settings.json"
BASE='{"otel":{"enabled":true,"endpoint":"","queueMaxSizeMB":2},"log":{"dir":"__LOGDIR__","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"skills":{"orgPluginPrefix":"pc-"}}'

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

trap 'rm -rf "$WORK"' EXIT

# Fake ~/.claude and ~/.copilot (a pc-demo plugin, personal skills/commands) so tests never read the real homes.
FIXTURES="$WORK/fixtures"
cp -r "$HERE/fixtures" "$FIXTURES"
IP="$FIXTURES/claude-home/plugins/installed_plugins.json"
sed "s#__FIXTURES__#$FIXTURES#g" "$IP" > "$IP.tmp" && mv -f "$IP.tmp" "$IP"
export AIHOOKS_CLAUDE_HOME="$FIXTURES/claude-home"
export AIHOOKS_COPILOT_HOME="$FIXTURES/copilot-home"
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
count_in() { printf '%s' "$1" | grep -o "$2" | wc -l | tr -d ' '; }

echo ""
echo "== Contract fixtures =="
for case_dir in "$CASES"/*/; do
  name="$(basename "$case_dir")"
  # Effective settings: per-case override or base template, with the temp log dir injected.
  if [ -f "$case_dir/settings.json" ]; then tmpl="$(cat "$case_dir/settings.json")"; else tmpl="$BASE"; fi
  printf '%s' "${tmpl//__LOGDIR__/$LOGDIR}" > "$SETTINGS"
  export AIHOOKS_SETTINGS="$SETTINGS"
  rm -f "$LOGDIR"/* 2>/dev/null

  if [ -f "$case_dir/requires" ] && grep -q jq "$case_dir/requires" && [ "$HAS_JQ" = 0 ]; then
    printf '  SKIP  %s (needs jq)\n' "$name"; continue
  fi
  read -r ev ag < "$case_dir/cmd"
  [ -z "$ag" ] && ag="test"
  errf="$WORK/err.txt"
  STDOUT="$("$DISPATCH" "$ev" "$ag" < "$case_dir/payload.json" 2>"$errf")"
  EXIT=$?
  STDERR="$(cat "$errf" 2>/dev/null)"
  SECLOG="$(cat "$LOGDIR/security.jsonl" 2>/dev/null)"
  TELEMETRY="$(cat "$LOGDIR/telemetry-queue.jsonl" 2>/dev/null)"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    dir="${line%% *}"; rest="${line#* }"
    case "$dir" in
      exit)
        if [ "$EXIT" = "$rest" ]; then ok "$name : exit $rest"; else bad "$name : exit $rest" "got $EXIT"; fi ;;
      stdout_empty)
        if [ -z "$(printf '%s' "$STDOUT" | tr -d '[:space:]')" ]; then ok "$name : stdout empty"; else bad "$name : stdout empty" "$STDOUT"; fi ;;
      stdout|stderr|seclog|telemetry)
        op="${rest%% *}"; operand="${rest#* }"
        case "$dir" in
          stdout) hay="$STDOUT" ;; stderr) hay="$STDERR" ;;
          seclog) hay="$SECLOG" ;; telemetry) hay="$TELEMETRY" ;;
        esac
        if [ "$op" = "~" ]; then
          if contains "$hay" "$operand"; then ok "$name : $dir ~ $operand"; else bad "$name : $dir ~ $operand" "not present"; fi
        else
          if contains "$hay" "$operand"; then bad "$name : $dir !~ $operand" "present"; else ok "$name : $dir !~ $operand"; fi
        fi ;;
    esac
  done < "$case_dir/expect"
done

echo ""
echo "== Multi-run checks (dedupe, inventory throttle) =="
printf '%s' "${BASE//__LOGDIR__/$LOGDIR}" > "$SETTINGS"
export AIHOOKS_SETTINGS="$SETTINGS"
QUEUE="$LOGDIR/telemetry-queue.jsonl"
run() { printf '%s' "$3" | "$DISPATCH" "$1" "$2" >/dev/null 2>&1; }

rm -f "$LOGDIR"/* 2>/dev/null
run UserPromptSubmit claude-code '{"prompt":"/pc-demo:deploy to staging","session_id":"dd-1"}'
run PreToolUse claude-code '{"tool_name":"Skill","tool_input":{"skill":"pc-demo:deploy"},"session_id":"dd-1"}'
n="$(count_in "$(cat "$QUEUE" 2>/dev/null)" 'pc.ai.skill_usage')"
[ "$n" = 1 ] && ok 'dedupe: /cmd prompt + Skill tool in same session = 1 use' || bad 'dedupe: same session = 1 use' "got $n"
run PreToolUse claude-code '{"tool_name":"Skill","tool_input":{"skill":"pc-demo:deploy"},"session_id":"dd-2"}'
n="$(count_in "$(cat "$QUEUE" 2>/dev/null)" 'pc.ai.skill_usage')"
[ "$n" = 2 ] && ok 'dedupe: another session counts again' || bad 'dedupe: another session counts again' "got $n"

rm -f "$LOGDIR"/* 2>/dev/null
REPO_DIR="$WORK/my-folder"
mkdir -p "$REPO_DIR" && git -C "$REPO_DIR" init -q && git -C "$REPO_DIR" remote add origin 'https://github.com/owner/NombreRepo.git'
run PreToolUse claude-code "{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"pc-demo:deploy\"},\"session_id\":\"prj-1\",\"cwd\":\"$REPO_DIR\"}"
q="$(cat "$QUEUE" 2>/dev/null)"
if contains "$q" 'owner/NombreRepo' && contains "$q" 'my-folder'; then ok 'project: git origin -> pc.project, folder -> pc.folder'; else bad 'project from git origin' "$q"; fi

if [ "$HAS_JQ" = 1 ]; then
  rm -f "$LOGDIR"/* 2>/dev/null
  run SessionStart claude-code '{"session_id":"inv-1"}'
  first="$(count_in "$(cat "$QUEUE" 2>/dev/null)" 'pc.ai.inventory')"
  run SessionStart claude-code '{"session_id":"inv-1"}'
  second="$(count_in "$(cat "$QUEUE" 2>/dev/null)" 'pc.ai.inventory')"
  if [ "$first" -ge 3 ] && [ "$second" = "$first" ]; then ok "inventory: sent once ($first records), throttled on the next session"; else bad 'inventory throttle' "first=$first second=$second"; fi
  mkdir -p "$FIXTURES/claude-home/skills/new-skill"; printf -- '---\nname: new-skill\n---\n' > "$FIXTURES/claude-home/skills/new-skill/SKILL.md"
  run SessionStart claude-code '{"session_id":"inv-1"}'
  third="$(count_in "$(cat "$QUEUE" 2>/dev/null)" 'pc.ai.inventory')"
  [ "$third" -gt "$second" ] && ok 'inventory: resent when what is installed changes' || bad 'inventory: resent on change' "second=$second third=$third"
  rm -rf "$FIXTURES/claude-home/skills/new-skill"
else
  printf '  SKIP  inventory throttle (needs jq)\n'
fi
unset AIHOOKS_SETTINGS

echo ""
echo "== Sending (mock OTLP collector) =="
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import http.server' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ] || [ "$HAS_JQ" = 0 ]; then
  printf '  SKIP  sending tests (need python3 + jq)\n'
else
  MOCK="$WORK/mock"; mkdir -p "$MOCK"
  "$PY" "$HERE/mock-otlp.py" "$MOCK" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MOCK/port" ] && break; sleep 0.5; done
  EP="http://127.0.0.1:$(cat "$MOCK/port")"
  mock_reset() { rm -f "$MOCK/requests.jsonl"; printf '%s' "${1:-200}" > "$MOCK/mode.txt"; }
  mock_count() { grep -c . "$MOCK/requests.jsonl" 2>/dev/null || echo 0; }
  mock_bodies() { cat "$MOCK/requests.jsonl" 2>/dev/null; }
  send_settings() { # send_settings <endpoint> <extra-otel-json> [log-dir]
    printf '{"otel":{"enabled":true,"endpoint":"%s","queueMaxSizeMB":2%s},"log":{"dir":"%s","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"skills":{"orgPluginPrefix":"pc-"}}' \
      "$1" "$2" "${3:-$LOGDIR}" > "$SETTINGS"
    export AIHOOKS_SETTINGS="$SETTINGS"
  }
  queue_records() { # queue_records <n>
    local i; : > "$QUEUE"
    for ((i = 1; i <= $1; i++)); do
      printf '{"timeUnixNano":"1","severityText":"INFO","severityNumber":9,"body":{"stringValue":"pc.ai.skill_usage"},"attributes":[{"key":"pc.skill","value":{"stringValue":"s%s"}}]}\n' "$i" >> "$QUEUE"
    done
  }
  queue_files() { ls "$LOGDIR"/telemetry-queue* 2>/dev/null | wc -l | tr -d ' '; }

  # selftest: OK against the mock, headers sent, severity + resource attributes in the payload
  rm -f "$LOGDIR"/* 2>/dev/null; mock_reset
  send_settings "$EP" ',"background":false,"headers":{"Authorization":"Bearer t0k3n"}'
  out="$("$DISPATCH" selftest test </dev/null)"; code=$?
  if [ "$code" = 0 ] && contains "$out" '"ok":true' && contains "$out" 'Authorization' && ! contains "$out" 't0k3n'; then ok 'selftest: ok against the collector (header names only)'; else bad 'selftest: ok' "exit=$code $out"; fi
  if [ "$(mock_count)" = 1 ] && contains "$(mock_bodies)" '"auth": "Bearer t0k3n"'; then ok 'selftest: Authorization header sent'; else bad 'selftest: header' "$(mock_bodies | cut -c1-200)"; fi
  b="$(mock_bodies)"
  if contains "$b" 'pc.ai.selftest' && contains "$b" 'severityNumber\":9' && contains "$b" 'service.version' && contains "$b" 'host.name' && contains "$b" 'os.type'; then
    ok 'payload: severity + resource attributes'; else bad 'payload: severity + resource' "$(printf '%s' "$b" | cut -c1-300)"; fi

  # selftest: endpoint down -> ok false, exit 1
  send_settings 'http://127.0.0.1:1' ',"background":false'
  out="$("$DISPATCH" selftest test </dev/null)"; code=$?
  if [ "$code" = 1 ] && contains "$out" '"ok":false'; then ok 'selftest: endpoint down -> ok false, exit 1'; else bad 'selftest: endpoint down' "exit=$code $out"; fi

  # flush: 450 records, batches of 200 -> 3 requests, queue gone
  rm -f "$LOGDIR"/* 2>/dev/null; mock_reset
  send_settings "$EP" ',"background":false,"flushBatchSize":200'
  queue_records 450
  out="$("$DISPATCH" flush test </dev/null)"
  if [ "$(mock_count)" = 3 ] && [ "$(queue_files)" = 0 ] && contains "$out" '"sent":450'; then ok 'flush: 450 records in 3 batches, queue emptied'; else bad 'flush: batches' "requests=$(mock_count) files=$(queue_files) $out"; fi

  # flush: second batch fails -> first stays sent, the rest is kept and retried first next time
  rm -f "$LOGDIR"/* 2>/dev/null; mock_reset 'okleft 1'
  queue_records 450
  out="$("$DISPATCH" flush test </dev/null)"
  left="$(cat "$LOGDIR"/telemetry-queue.sending-*.jsonl 2>/dev/null | grep -c .)"
  if contains "$out" '"sent":200' && [ "$left" = 250 ]; then ok 'flush: failure keeps only the unsent records (250)'; else bad 'flush: partial failure' "left=$left $out"; fi
  mock_reset
  "$DISPATCH" flush test </dev/null >/dev/null
  if [ "$(queue_files)" = 0 ] && [ "$(mock_count)" = 2 ]; then ok 'flush: pending records retried and sent'; else bad 'flush: retry' "files=$(queue_files) requests=$(mock_count)"; fi

  # lock: a fresh lock skips the flush; a stale one (crashed worker) does not
  rm -rf "$LOGDIR"/* 2>/dev/null; mock_reset
  queue_records 3
  mkdir -p "$LOGDIR/flush.lock.d"
  out="$("$DISPATCH" flush test </dev/null)"
  if contains "$out" 'locked' && [ "$(mock_count)" = 0 ]; then ok 'flush: concurrent flush skipped (lock)'; else bad 'flush: lock' "$out"; fi
  touch -d '-5 minutes' "$LOGDIR/flush.lock.d" 2>/dev/null || touch -t "$(date -v-5M +%Y%m%d%H%M 2>/dev/null)" "$LOGDIR/flush.lock.d"
  out="$("$DISPATCH" flush test </dev/null)"
  if contains "$out" '"sent":3'; then ok 'flush: stale lock ignored'; else bad 'flush: stale lock' "$out"; fi

  # records dropped by queue rotation are counted and reported on the next successful flush
  rm -rf "$LOGDIR"/* 2>/dev/null; mock_reset
  send_settings '' ',"queueMaxSizeMB":0.0005'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do run PreToolUse claude-code "{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"rot-$i\"},\"session_id\":\"rot\"}"; done
  dropped="$(tr -dc '0-9' < "$LOGDIR/state-dropped.txt" 2>/dev/null)"
  if [ "${dropped:-0}" -gt 0 ]; then ok "queue rotation: $dropped dropped records counted"; else bad 'queue rotation: dropped count' 'state-dropped.txt missing'; fi
  send_settings "$EP" ',"background":false'
  "$DISPATCH" flush test </dev/null >/dev/null
  if contains "$(mock_bodies)" 'pc.dropped' && [ ! -f "$LOGDIR/state-dropped.txt" ]; then ok 'queue rotation: pc.dropped reported, counter reset'; else bad 'queue rotation: report' ''; fi

  # background: the hook only queues; a detached worker delivers it
  rm -rf "$LOGDIR"/* 2>/dev/null; mock_reset
  send_settings "$EP" ',"background":true'
  run UserPromptSubmit claude-code '{"prompt":"/pc-demo:deploy now","session_id":"bg-1"}'
  for _ in $(seq 1 60); do contains "$(mock_bodies)" 'pc.ai.skill_usage' && break; sleep 0.5; done
  sleep 1
  if contains "$(mock_bodies)" 'pc.ai.skill_usage' && [ "$(queue_files)" = 0 ]; then ok 'background: detached worker delivered the queue'; else bad 'background: worker delivery' "files=$(queue_files)"; fi

  # background SessionStart: inventory built and sent by the worker
  rm -rf "$LOGDIR"/* 2>/dev/null; mock_reset
  run SessionStart claude-code '{"session_id":"bg-inv"}'
  for _ in $(seq 1 180); do contains "$(mock_bodies)" 'pc.ai.inventory' && break; sleep 0.5; done
  if contains "$(mock_bodies)" 'pc.ai.inventory' && contains "$(mock_bodies)" 'bg-inv'; then ok 'background: SessionStart inventory sent by the worker'; else bad 'background: inventory worker' ''; fi

  # latency: endpoint unreachable -> the background hook does not wait for the network
  LAT="$WORK/lat"; mkdir -p "$LAT"
  hook_ms() { local t0 t1; t0="$(now_ms)"; printf '%s' '{"prompt":"hello","session_id":"lat"}' | "$DISPATCH" UserPromptSubmit test >/dev/null 2>&1; t1="$(now_ms)"; echo $((t1 - t0)); }
  now_ms() { local n; n="$(date +%s%N 2>/dev/null)"; case "$n" in *N|'') echo $(( $(date +%s) * 1000 )) ;; *) echo $(( n / 1000000 )) ;; esac; }
  send_settings '' ',"background":true' "$LAT"; base="$(hook_ms)"
  send_settings 'http://10.255.255.1:4318' ',"background":true' "$LAT"
  printf '%s\n' '{"timeUnixNano":"1","severityText":"INFO","severityNumber":9,"body":{"stringValue":"pc.ai.skill_usage"},"attributes":[]}' > "$LAT/telemetry-queue.jsonl"
  bgq="$(hook_ms)"
  if [ "$bgq" -lt $((base + 1500)) ]; then ok "latency: unreachable endpoint does not slow the hook (base ${base} ms, background ${bgq} ms)"; else bad 'latency' "base=$base bg=$bgq"; fi

  kill "$MOCK_PID" 2>/dev/null
  unset AIHOOKS_SETTINGS
fi

echo ""
echo "== Unit checks =="
export AIHOOKS_ROOT="$ROOT"
SP="$ROOT/layers/policy/scan-prompt.sh"
SU="$ROOT/layers/usage/usage.sh"

out="$("$SP" 'key AKIA1234567890ABCDEF here')"
case "$out" in AWS_ACCESS_KEY\|critical*) ok 'scan: AWS critical' ;; *) bad 'scan: AWS critical' "$out" ;; esac
out="$("$SP" 'AKIAEXAMPLEKEY123456')"
[ -z "$out" ] && ok 'scan: placeholder filtered' || bad 'scan: placeholder filtered' "$out"
out="$("$SP" 'card 4111111111111111')"
contains "$out" 'CREDIT_CARD' && ok 'scan: valid Luhn card detected' || bad 'scan: valid Luhn card detected' "$out"
out="$("$SP" 'card 4111111111111112')"
contains "$out" 'CREDIT_CARD' && bad 'scan: invalid Luhn rejected' "$out" || ok 'scan: invalid Luhn rejected'
# generic secret uses a POSIX class -> must still fire under grep -E
out="$("$SP" 'config password = S3cretValue123XY here')"
contains "$out" 'GENERIC_SECRET|high' && ok 'scan: GENERIC_SECRET high' || bad 'scan: GENERIC_SECRET high' "$out"

# output: SKILL|PLUGIN|SOURCE|KIND|VIA|VERSION|MARKETPLACE|RAW
out="$("$SU" "" "pc-ai:debugger" "skill")"
[ "$out" = "debugger|pc-ai|plainconcepts|skill|tool|||pc-ai:debugger" ] && ok 'skill: pc- => plainconcepts' || bad 'skill: pc- => plainconcepts' "$out"
out="$("$SU" "" "anthropic-skills:docx" "skill")"
[ "$out" = "docx|anthropic-skills|plugin|skill|tool|||anthropic-skills:docx" ] && ok 'skill: other plugin => plugin' || bad 'skill: other plugin => plugin' "$out"
out="$("$SU" "" "my-local-skill" "skill")"
[ "$out" = "my-local-skill||personal|skill|tool|||my-local-skill" ] && ok 'skill: bare => personal' || bad 'skill: bare => personal' "$out"
out="$("$SU" "/usr/bin/env python" "" "")"
[ -z "$out" ] && ok 'skill: leading path is not a command' || bad 'skill: leading path is not a command' "$out"
out="$("$SU" "please /build now" "" "")"
[ -z "$out" ] && ok 'skill: bare /word ignored' || bad 'skill: bare /word ignored' "$out"

ver="$("$DISPATCH" version </dev/null)"; vexit=$?
if [ "$vexit" = "0" ] && printf '%s' "$ver" | grep -qE '"version":"[0-9]+\.[0-9]+\.[0-9]+\+g'; then
  ok 'dispatch version -> json, exit 0'
else
  bad 'dispatch version' "exit=$vexit $ver"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
