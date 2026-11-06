#!/usr/bin/env bash
# install-hodor.sh - One-step install of the Hodor pilot (AI hooks) on Linux / macOS.
#
# Usage (no root needed). The script clones the repo itself, so this is the only step:
#   bash <(curl -fsSL https://raw.githubusercontent.com/PlainConceptsPlatform/Hodor/main/pilot/install-hodor.sh)
# or, from a clone:
#   bash ~/Hodor/pilot/install-hodor.sh [--token <TOKEN>] [--email <EMAIL>] [--repo-dir <DIR>]
# Hodor itself is always installed from a git clone (never a zip: the version is stamped from git).
#
# What it does:
#   1. Checks prerequisites (git, curl, jq) and asks for the ingest token
#   2. Clones the repo into ~/Hodor (or git-pulls it if already there / if run from a clone)
#   3. Resolves your corporate email
#   4. Installs Hodor into ~/.local/share/plainconcepts/ai-hooks and wires the Claude Code + Copilot hooks
#   5. Enables chat.useHooks in VS Code (if installed)
#   6. Runs the selftest to check telemetry gets through
#
# Bash 3.2 compatible (macOS default shell).

# --- Pilot configuration --------------------------------------------------------
REPO_URL='https://github.com/PlainConceptsPlatform/Hodor.git'
OTEL_ENDPOINT='https://atlas-api.plainconcepts.com/api/v1/ai-hooks'
DEFAULT_TOKEN=''   # optional: fill in before handing out the script so it does not ask for the token
CORP_DOMAIN='plainconcepts.com'
INSTALL_DIR="${HOME}/.local/share/plainconcepts/ai-hooks"
# -------------------------------------------------------------------------------

TOKEN=""; EMAIL=""; REPO_DIR=""; NO_UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --token)     TOKEN="$2"; shift 2 ;;
    --email)     EMAIL="$2"; shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --endpoint)  OTEL_ENDPOINT="$2"; shift 2 ;;   # override the Atlas endpoint (tests, other environments)
    --no-update) NO_UPDATE=1; shift ;;            # do not git pull an existing clone (tests)
    -h|--help)  sed -n '2,17p' "$0" 2>/dev/null; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""; fi
step() { echo ""; echo "${C_CYAN}[$1/6] $2${C_OFF}"; }
ok()   { echo "  ${C_GREEN}[OK]${C_OFF} $1"; }
warn() { echo "  ${C_YELLOW}[!]${C_OFF}  $1"; }
fail() { echo "  ${C_RED}[X]${C_OFF}  $1"; exit 1; }
# Prompts read from the terminal, so they also work when the script itself comes from a pipe
ask()  { local v; printf '  %s' "$1" > /dev/tty; IFS= read -r v < /dev/tty; printf '%s' "$v"; }
ask_secret() { local v; printf '  %s' "$1" > /dev/tty; IFS= read -rs v < /dev/tty; echo > /dev/tty; printf '%s' "$v"; }
is_email() { printf '%s' "$1" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; }

echo "== Hodor pilot installation =="

# 1. Prerequisites ----------------------------------------------------------------
step 1 "Checking prerequisites"
missing=""
for c in git curl jq; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
if [ -n "$missing" ]; then
  echo "  Missing:$missing. Install them and run this again, e.g.:"
  echo "    Ubuntu/Debian: sudo apt-get install -y$missing"
  echo "    Fedora/RHEL:   sudo dnf install -y$missing"
  echo "    macOS:         brew install$missing"
  fail "Prerequisites not met"
fi
ok "git, curl and jq found"

[ -z "$TOKEN" ] && TOKEN="$DEFAULT_TOKEN"
[ -z "$TOKEN" ] && TOKEN="${HODOR_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN="$(ask_secret "Paste the Atlas token: ")"
TOKEN="$(printf '%s' "$TOKEN" | sed -E 's/^[[:space:]]*Bearer[[:space:]]+//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -n "$TOKEN" ] || fail "No token provided."
ok "Token received"

# 2. Repo -------------------------------------------------------------------------
# Run from a clone (pilot/install-hodor.sh)? Use that clone unless --repo-dir was given.
if [ -z "$REPO_DIR" ]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  self_repo="$(dirname "$self_dir" 2>/dev/null)"
  if [ -n "$self_dir" ] && [ -d "$self_repo/.git" ] && [ -f "$self_repo/dispatch.sh" ]; then
    REPO_DIR="$self_repo"
  else
    REPO_DIR="$HOME/Hodor"
  fi
fi
step 2 "Getting Hodor into $REPO_DIR"
if [ -d "$REPO_DIR/.git" ] && [ "$NO_UPDATE" = 1 ]; then
  ok "Using $REPO_DIR as is (--no-update)"
elif [ -d "$REPO_DIR/.git" ]; then
  if git -C "$REPO_DIR" pull --ff-only; then ok "Repo updated"
  else warn "Could not update $REPO_DIR (git pull); installing the local copy as is."; fi
elif [ -e "$REPO_DIR" ]; then
  fail "$REPO_DIR already exists and is not a git repo. Delete it or pass --repo-dir <another folder>."
else
  git clone "$REPO_URL" "$REPO_DIR" || fail "Could not clone $REPO_URL"
  ok "Repo cloned"
fi
[ -f "$REPO_DIR/dispatch.sh" ] || fail "$REPO_DIR/dispatch.sh not found"

# 3. Identity -----------------------------------------------------------------------
step 3 "Resolving your corporate identity"
if [ -z "$EMAIL" ]; then
  # No UPN outside Windows: take the first corporate address among the Claude account and git
  claude_email="$(jq -r '.oauthAccount.emailAddress // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)"
  git_email="$(git config --global user.email 2>/dev/null)"
  for e in "$claude_email" "$git_email"; do
    e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
    case "$e" in *@"$CORP_DOMAIN") EMAIL="$e"; break ;; esac
  done
fi
if ! is_email "$EMAIL"; then
  warn "Could not find your corporate email automatically."
  EMAIL="$(ask "Type your corporate email (@$CORP_DOMAIN): ")"
fi
EMAIL="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
is_email "$EMAIL" || fail "Invalid email: '$EMAIL'"
case "$EMAIL" in *@"$CORP_DOMAIN") ;; *) warn "Identity '$EMAIL' is not @$CORP_DOMAIN. Make sure it is your corporate account." ;; esac
ok "Identity: $EMAIL"

# 4. Install ------------------------------------------------------------------------
step 4 "Installing hooks into $INSTALL_DIR"
dest_cfg="$INSTALL_DIR/config/settings.json"
prev_cfg="{}"
[ -f "$dest_cfg" ] && prev_cfg="$(jq -c . "$dest_cfg" 2>/dev/null || echo '{}')"

# Reinstall: drop the previous code (keep config/ and logs/) so files removed from the repo do not linger
mkdir -p "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/dispatch.sh" ]; then
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name config ! -name logs -exec rm -rf {} +
fi
# Copy the repo without its .git history (version comes from build-info.json, stamped below)
( cd "$REPO_DIR" && tar --exclude=./.git -cf - . ) | ( cd "$INSTALL_DIR" && tar -xf - ) || fail "Could not copy the files"
chmod +x "$INSTALL_DIR/dispatch.sh" "$INSTALL_DIR"/tools/*.sh 2>/dev/null
find "$INSTALL_DIR/layers" -name '*.sh' -exec chmod +x {} + 2>/dev/null
ok "Files copied"

# Config: repo defaults, previous installed values on top, then the pilot values
jq --argjson prev "$prev_cfg" --arg ep "$OTEL_ENDPOINT" --arg tok "Bearer $TOKEN" --arg mail "$EMAIL" \
   '. * $prev | .otel.enabled = true | .otel.endpoint = $ep | .otel.headers = ((.otel.headers // {}) + {Authorization: $tok})
    | .identity.email = $mail' \
   "$REPO_DIR/config/settings.json" > "$dest_cfg.tmp" && mv "$dest_cfg.tmp" "$dest_cfg" || fail "Could not write $dest_cfg"
chmod 600 "$dest_cfg"   # holds the ingest token
ok "Config: $dest_cfg"

# build-info.json: full version derived from git in the source clone
base="$(head -n1 "$REPO_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"; [ -z "$base" ] && base="0.0"
sha="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
count="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ -n "$sha" ]; then
  jq -n --arg v "$base.$count+g$sha" --arg b "$base" --arg c "$sha" --argjson n "$count" \
        --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: $v, base: $b, commit: $c, commitCount: $n, buildDate: $d}' > "$INSTALL_DIR/build-info.json"
  ok "Version: $base.$count+g$sha"
else
  warn "No git info in $REPO_DIR; version will show as unknown"
fi

log_dir="$(jq -r '.log.dir // empty' "$dest_cfg")"; [ -z "$log_dir" ] && log_dir="$HOME/.local/state/plainconcepts/ai-hooks"
mkdir -p "$log_dir"

# Copilot hook (VS Code + Copilot CLI): the adapter already carries the bash command; point it at this install
mkdir -p "$HOME/.copilot/hooks"
copilot_hook="$HOME/.copilot/hooks/company-hooks.json"
jq --arg d "$INSTALL_DIR" '.hooks |= with_entries(.value |= map(.bash |= sub("/opt/plainconcepts/ai-hooks"; $d)))' \
   "$REPO_DIR/adapters/copilot/company-hooks.json" > "$copilot_hook.tmp" && mv "$copilot_hook.tmp" "$copilot_hook" \
   && ok "Copilot hook: $copilot_hook" || warn "Could not write $copilot_hook"

# Claude Code hooks: derived from the shared fragment (same events/matchers/timeouts), with the bash dispatcher
claude_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
mkdir -p "$(dirname "$claude_settings")"
track_reads="$(jq -r '.usage.trackFileReads // false' "$dest_cfg")"
# Each PowerShell command '... dispatch.ps1" -Event <E> -Agent claude-code' becomes '"<install>/dispatch.sh" <E> claude-code'
fragment="$(jq -c --arg d "$INSTALL_DIR" --arg tr "$track_reads" '
  def bashify: .command |= ("\"" + $d + "/dispatch.sh\" " + (capture("-Event (?<e>[A-Za-z]+)").e) + " claude-code");
  ._trackFileReads as $extra
  | (.hooks | map_values(map(.hooks |= map(bashify))))
  | if $tr == "true" then .PreToolUse += [($extra | {matcher, hooks: (.hooks | map(bashify))})] else . end
' "$REPO_DIR/adapters/claude/hooks-fragment.json" 2>/dev/null)"
[ -n "$fragment" ] || fail "Could not build the Claude Code hooks from adapters/claude/hooks-fragment.json"
if [ -f "$claude_settings" ]; then
  jq -e . "$claude_settings" >/dev/null 2>&1 || fail "$claude_settings is not valid JSON; fix it and run this again."
  cp "$claude_settings" "$claude_settings.bak"
  current="$(cat "$claude_settings")"
else
  current='{}'
fi
# Replace any previous Hodor hook groups (any install path, bash or PowerShell) and keep everything else
printf '%s' "$current" | jq --argjson frag "$fragment" '
  def ours: any(.hooks[]?; (.command // "") | test("ai-hooks[/\\\\]dispatch\\.(sh|ps1)"));
  .hooks = ((.hooks // {}) as $h
    | reduce ($frag | keys[]) as $ev ($h; .[$ev] = ((($h[$ev] // []) | map(select(ours | not))) + $frag[$ev])))
' > "$claude_settings.tmp" && mv "$claude_settings.tmp" "$claude_settings" \
  || fail "Could not update $claude_settings"
ok "Claude Code hooks: $claude_settings$([ -f "$claude_settings.bak" ] && echo ' (backup: .bak)')"

# Doctor: version + paths + hook wiring
echo ""
bash "$INSTALL_DIR/tools/hodor-version.sh" | sed 's/^/  /'

# 5. VS Code: chat.useHooks -------------------------------------------------------
step 5 "Enabling chat.useHooks in VS Code"
if [ "$(uname -s)" = "Darwin" ]; then vs_dir="$HOME/Library/Application Support/Code/User"
else vs_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"; fi
vs_settings="$vs_dir/settings.json"
if [ ! -d "$vs_dir" ]; then
  warn "VS Code does not seem to be installed for this user. Skipped."
else
  [ -s "$vs_settings" ] || echo '{}' > "$vs_settings"
  if ! jq -e . "$vs_settings" >/dev/null 2>&1; then
    # jq cannot parse JSONC (comments / trailing commas)
    warn "Your VS Code settings.json has comments or non-standard formatting; leaving it untouched."
    warn "Enable it by hand: Settings > search 'chat.useHooks' > tick it."
  elif [ "$(jq -r '."chat.useHooks" // false' "$vs_settings")" = "true" ]; then
    ok "Already enabled"
  else
    cp "$vs_settings" "$vs_settings.hodor.bak"
    jq '."chat.useHooks" = true' "$vs_settings.hodor.bak" > "$vs_settings" && ok "Enabled (backup: settings.json.hodor.bak)"
  fi
fi

# 6. Selftest -----------------------------------------------------------------------
step 6 "Checking telemetry delivery (selftest)"
out="$("$INSTALL_DIR/dispatch.sh" selftest 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '"ok":true'; then
  selftest_ok=1; ok "Telemetry reaches Atlas"
else
  selftest_ok=0; warn "The selftest failed. Send this output to whoever gave you this script:"; echo "$out"
fi

# Summary ---------------------------------------------------------------------------
echo ""
echo "${C_GREEN}== Done ==${C_OFF}"
echo "Next steps:"
echo "  1. Close and reopen Claude Code."
echo "  2. In VS Code: Ctrl+Shift+P (Cmd+Shift+P on macOS) > 'Developer: Reload Window'."
echo "  3. Run the test battery:"
echo "     https://github.com/PlainConceptsPlatform/Hodor/blob/main/docs/manual-test-battery.md"
echo ""
echo "Diagnostics if something goes wrong:"
echo "  bash \"$INSTALL_DIR/tools/hodor-version.sh\""
echo "Uninstall:"
echo "  bash \"$REPO_DIR/pilot/uninstall-hodor.sh\""
[ "$selftest_ok" = 1 ] || exit 2
