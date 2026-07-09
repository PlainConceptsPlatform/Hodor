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
BASE='{"otel":{"enabled":true,"endpoint":"","queueMaxSizeMB":2},"log":{"dir":"__LOGDIR__","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"policy":{"blockSeverity":"critical"},"skills":{"orgPluginPrefix":"pc-"}}'

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

trap 'rm -rf "$WORK"' EXIT

echo ""
echo "== Contract fixtures =="
for case_dir in "$CASES"/*/; do
  name="$(basename "$case_dir")"
  # Effective settings: per-case override or base template, with the temp log dir injected.
  if [ -f "$case_dir/settings.json" ]; then tmpl="$(cat "$case_dir/settings.json")"; else tmpl="$BASE"; fi
  printf '%s' "${tmpl//__LOGDIR__/$LOGDIR}" > "$SETTINGS"
  export AIHOOKS_SETTINGS="$SETTINGS"
  rm -f "$LOGDIR"/* 2>/dev/null

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
unset AIHOOKS_SETTINGS

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

out="$("$SU" "" "pc-ai:debugger" "skill")"
[ "$out" = "debugger|pc-ai|plainconcepts|skill" ] && ok 'skill: pc- => plainconcepts' || bad 'skill: pc- => plainconcepts' "$out"
out="$("$SU" "" "anthropic-skills:docx" "skill")"
[ "$out" = "docx|anthropic-skills|plugin|skill" ] && ok 'skill: other plugin => plugin' || bad 'skill: other plugin => plugin' "$out"
out="$("$SU" "" "my-local-skill" "skill")"
[ "$out" = "my-local-skill||personal|skill" ] && ok 'skill: bare => personal' || bad 'skill: bare => personal' "$out"
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
