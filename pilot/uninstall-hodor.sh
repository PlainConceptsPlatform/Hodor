#!/usr/bin/env bash
# uninstall-hodor.sh - Uninstalls the Hodor pilot (AI hooks) on Linux / macOS.
#
# Usage (no root needed). Close Claude Code and VS Code first:
#   bash ~/Hodor/pilot/uninstall-hodor.sh [--keep-repo] [--keep-logs] [--repo-dir <DIR>]
#
# What it does:
#   1. Stops Hodor background processes (telemetry sending)
#   2. Removes Hodor's hooks from ~/.claude/settings.json (other hooks and settings are kept)
#   3. Removes the Copilot hook (~/.copilot/hooks/company-hooks.json)
#   4. Deletes the install, the logs and, by default, the repo copy
#   5. Turns chat.useHooks in VS Code back off if install-hodor.sh enabled it
#
# Bash 3.2 compatible (macOS default shell). Needs jq.

INSTALL_DIR="${HOME}/.local/share/plainconcepts/ai-hooks"
REPO_DIR=""; KEEP_REPO=0; KEEP_LOGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-repo) KEEP_REPO=1; shift ;;
    --keep-logs) KEEP_LOGS=1; shift ;;   # tar.gz the logs into ~ before deleting
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,13p' "$0" 2>/dev/null; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_GREY=$'\033[90m'; C_OFF=$'\033[0m'
else C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_GREY=""; C_OFF=""; fi
PROBLEMS=0
step() { echo ""; echo "${C_CYAN}[$1/5] $2${C_OFF}"; }
ok()   { echo "  ${C_GREEN}[OK]${C_OFF} $1"; }
info() { echo "  ${C_GREY}[-]  $1${C_OFF}"; }
warn() { echo "  ${C_YELLOW}[!]${C_OFF}  $1"; PROBLEMS=$((PROBLEMS + 1)); }

# Run from a clone (pilot/uninstall-hodor.sh)? That clone is the repo to remove unless --repo-dir was given.
if [ -z "$REPO_DIR" ]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  self_repo="$(dirname "$self_dir" 2>/dev/null)"
  if [ -n "$self_dir" ] && [ -f "$self_repo/dispatch.sh" ] && [ -d "$self_repo/pilot" ]; then REPO_DIR="$self_repo"
  else REPO_DIR="$HOME/Hodor"; fi
fi
cd "$HOME" || exit 1   # do not keep the repo folder busy as the current directory

echo "== Hodor uninstall =="
echo "${C_GREY}Recommended: close Claude Code and VS Code before continuing.${C_OFF}"
command -v jq >/dev/null 2>&1 || { echo "jq is required (apt-get/dnf/brew install jq)."; exit 1; }

# Log folder (settings may override it)
LOG_DIR=""
[ -f "$INSTALL_DIR/config/settings.json" ] && LOG_DIR="$(jq -r '.log.dir // empty' "$INSTALL_DIR/config/settings.json" 2>/dev/null)"
[ -z "$LOG_DIR" ] && LOG_DIR="$HOME/.local/state/plainconcepts/ai-hooks"

# 1. Background processes -----------------------------------------------------------
step 1 "Stopping Hodor background processes"
if command -v pkill >/dev/null 2>&1 && pkill -f "$INSTALL_DIR/dispatch.sh" 2>/dev/null; then ok "Background processes stopped"
else info "No processes running"; fi

# 2. Claude Code ----------------------------------------------------------------------
step 2 "Removing Claude Code hooks"
claude_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ ! -f "$claude_settings" ]; then
  info "$claude_settings does not exist"
elif ! jq -e . "$claude_settings" >/dev/null 2>&1; then
  warn "$claude_settings is not valid JSON. Remove by hand the 'hooks' entries that contain ai-hooks/dispatch.sh"
else
  filter='
    def isours: ((.command // "") | test("ai-hooks[/\\\\]dispatch\\.(sh|ps1)"));
    if (.hooks | type) == "object" then
      .hooks |= (with_entries(.value |= (map(if has("hooks") then .hooks |= map(select(isours | not)) else . end)
                                         | map(select((has("hooks") | not) or (.hooks | length > 0)))))
                 | with_entries(select(.value | length > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end'
  removed="$(jq '[.hooks // {} | .[]? | .[]? | .hooks[]? | select((.command // "") | test("ai-hooks[/\\\\]dispatch\\.(sh|ps1)"))] | length' "$claude_settings")"
  if [ "${removed:-0}" -gt 0 ]; then
    cp "$claude_settings" "$claude_settings.hodor-uninstall.bak"
    jq "$filter" "$claude_settings.hodor-uninstall.bak" > "$claude_settings" \
      && ok "$removed hook(s) removed (backup: settings.json.hodor-uninstall.bak)" \
      || { cp "$claude_settings.hodor-uninstall.bak" "$claude_settings"; warn "Could not update $claude_settings (restored)"; }
  else
    info "No Hodor hooks found"
  fi
fi

# 3. Copilot (VS Code + Copilot CLI) -------------------------------------------------
step 3 "Removing the Copilot hook"
copilot_hook="$HOME/.copilot/hooks/company-hooks.json"
if [ ! -f "$copilot_hook" ]; then info "$copilot_hook does not exist"
elif grep -q 'ai-hooks' "$copilot_hook"; then rm -f "$copilot_hook" && ok "Removed $copilot_hook"
else info "$copilot_hook is not Hodor's; left untouched"; fi

# 4. Files ----------------------------------------------------------------------------
step 4 "Deleting files"
if [ "$KEEP_LOGS" = 1 ] && [ -d "$LOG_DIR" ]; then
  archive="$HOME/hodor-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$archive" -C "$LOG_DIR" . 2>/dev/null && ok "Logs saved to $archive" || warn "Could not save the logs"
fi
remove_dir() { # remove_dir <path> <label>
  if [ ! -e "$1" ]; then info "$1 does not exist"; return; fi
  rm -rf "$1" && ok "$2 removed: $1" || warn "Could not delete $1"
}
remove_dir "$INSTALL_DIR" "Install"
remove_dir "$LOG_DIR" "Logs"
rmdir "$(dirname "$INSTALL_DIR")" "$(dirname "$LOG_DIR")" 2>/dev/null   # empty plainconcepts/ parents
if [ "$KEEP_REPO" = 1 ]; then info "Keeping the repo at $REPO_DIR (--keep-repo)"
elif [ -f "$REPO_DIR/dispatch.sh" ] && [ -d "$REPO_DIR/pilot" ]; then remove_dir "$REPO_DIR" "Repo"
elif [ -e "$REPO_DIR" ]; then info "$REPO_DIR does not look like the Hodor repo; left untouched"
else info "$REPO_DIR does not exist"; fi
[ -d /opt/plainconcepts/ai-hooks ] && info "Another install exists at /opt/plainconcepts/ai-hooks (needs root to delete)"

# 5. VS Code --------------------------------------------------------------------------
step 5 "Checking chat.useHooks in VS Code"
if [ "$(uname -s)" = "Darwin" ]; then vs_settings="$HOME/Library/Application Support/Code/User/settings.json"
else vs_settings="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json"; fi
vs_backup="$vs_settings.hodor.bak"
if [ ! -f "$vs_backup" ]; then
  info "install-hodor.sh did not change VS Code; left untouched"
else
  was_on="$(jq -r '."chat.useHooks" // false' "$vs_backup" 2>/dev/null)"
  if [ "$was_on" != "true" ] && [ -f "$vs_settings" ] && jq -e 'has("chat.useHooks")' "$vs_settings" >/dev/null 2>&1; then
    tmp="$vs_settings.tmp"
    jq 'del(."chat.useHooks")' "$vs_settings" > "$tmp" && mv "$tmp" "$vs_settings" \
      && ok "chat.useHooks turned off (it was off before Hodor was installed)" || warn "Could not update $vs_settings"
  else
    info "chat.useHooks was already on before Hodor; left as is"
  fi
  rm -f "$vs_backup"
fi

# Summary -------------------------------------------------------------------------------
echo ""
if [ "$PROBLEMS" -eq 0 ]; then echo "${C_GREEN}== Hodor uninstalled ==${C_OFF}"
else echo "${C_YELLOW}== Uninstall finished with $PROBLEMS warning(s): check the [!] messages above ==${C_OFF}"; fi
echo "Restart Claude Code and reload VS Code so they stop loading the hooks."
[ "$PROBLEMS" -eq 0 ] || exit 1
