#!/usr/bin/env bash
# lib/plugins.sh - what is installed locally (Claude Code + Copilot plugins, personal skills/agents/commands).
# Used to (1) resolve a usage name to its kind/version/marketplace and (2) build the inventory snapshot.
# AIHOOKS_CLAUDE_HOME / AIHOOKS_COPILOT_HOME override the homes (test isolation; unset in production).
# Plugin indexes need jq; without it usage is still reported, just without version/marketplace enrichment.

claude_home()  { printf '%s' "${AIHOOKS_CLAUDE_HOME:-$HOME/.claude}"; }
copilot_home() { printf '%s' "${AIHOOKS_COPILOT_HOME:-$HOME/.copilot}"; }

frontmatter_name() { # frontmatter_name <file> -> 'name:' from the YAML frontmatter ('' if absent)
  [ -f "$1" ] || return 0
  head -n 15 "$1" 2>/dev/null | tr -d '\r' | awk '
    NR==1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }'
}

plugin_items() { # plugin_items <dir> -> 3 lines: skills csv, agents csv, commands csv (invocation names)
  local dir="$1" skills="" agents="" commands="" f n rel
  if [ -d "$dir/skills" ]; then
    for f in "$dir"/skills/*/SKILL.md; do
      [ -f "$f" ] || continue
      n="$(frontmatter_name "$f")"; [ -z "$n" ] && n="$(basename "$(dirname "$f")")"
      skills="$skills$n"$'\n'
    done
  fi
  if [ -d "$dir/agents" ]; then
    for f in "$dir"/agents/*.md; do
      [ -f "$f" ] || continue
      n="$(frontmatter_name "$f")"; [ -z "$n" ] && { n="$(basename "$f" .md)"; n="${n%.agent}"; }
      agents="$agents$n"$'\n'
    done
  fi
  if [ -d "$dir/commands" ]; then
    while IFS= read -r f; do
      rel="${f#"$dir/commands/"}"; rel="${rel%.md}"
      commands="$commands$(printf '%s' "$rel" | tr '/' ':')"$'\n'
    done < <(find "$dir/commands" -type f -name '*.md' 2>/dev/null)
  fi
  printf '%s' "$skills" | grep -v '^$' | sort -u | paste -sd, -
  printf '%s' "$agents" | grep -v '^$' | sort -u | paste -sd, -
  printf '%s' "$commands" | grep -v '^$' | sort -u | paste -sd, -
}

claude_installs() { # -> lines: id|plugin|marketplace|version|scope|projectPath|installPath
  local f
  f="$(claude_home)/plugins/installed_plugins.json"
  [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '(.plugins // {}) | to_entries[] | .key as $id | (.value | if type == "array" then .[] else . end)
         | [$id, ($id | sub("@[^@]*$"; "")), (if ($id | test("@")) then ($id | sub("^.*@"; "")) else "" end),
            (.version // ""), (.scope // "user"), (.projectPath // ""), (.installPath // "")] | join("|")' "$f" 2>/dev/null \
    | tr -d '\r' | tr '\\' '/'
}

copilot_installs() { # -> lines: id|plugin|marketplace|version|scope|projectPath|installPath
  local root d c market name version
  root="$(copilot_home)/installed-plugins"
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    d="${d%/}"
    if [ -f "$d/plugin.json" ]; then
      set -- "$d|"
    else
      set --
      for c in "$d"/*/; do c="${c%/}"; [ -f "$c/plugin.json" ] && set -- "$@" "$c|$(basename "$d")"; done
    fi
    for entry in "$@"; do
      c="${entry%%|*}"; market="${entry#*|}"; [ "$market" = "_direct" ] && market="direct"
      name=""; version=""
      if command -v jq >/dev/null 2>&1; then
        name="$(jq -r '.name // empty' "$c/plugin.json" 2>/dev/null)"
        version="$(jq -r '.version // empty' "$c/plugin.json" 2>/dev/null)"
      fi
      [ -z "$name" ] && name="$(basename "$c")"
      printf '%s|%s|%s|%s|user||%s\n' "$name${market:+@$market}" "$name" "$market" "$version" "$c"
    done
  done
}

item_kind() { # item_kind <root> <name> -> command | skill | agent | '' (what <name> is inside a plugin/personal root)
  local dir="$1" rel
  [ -n "$dir" ] && [ -d "$dir" ] && [ -n "$2" ] || return 0
  rel="$(printf '%s' "$2" | tr ':' '/')"
  if [ -f "$dir/commands/$rel.md" ]; then printf 'command'
  elif [ -f "$dir/skills/$rel/SKILL.md" ]; then printf 'skill'
  elif [ -f "$dir/agents/$rel.md" ] || [ -f "$dir/agents/$rel.agent.md" ]; then printf 'agent'
  elif [ -d "$dir/agents" ]; then
    # Agents are invoked by their frontmatter name (e.g. pc.presales.discovery for agents/discovery.agent.md)
    local f
    for f in "$dir"/agents/*.md; do
      [ -f "$f" ] && [ "$(frontmatter_name "$f")" = "$2" ] && { printf 'agent'; return; }
    done
  fi
}

agent_canonical() { # agent_canonical <root> <name> -> frontmatter name of agents/<name>(.agent).md, else <name>
  # Claude Code invokes an agent by its frontmatter name, Copilot by its file name: report both under the former.
  local rel f fm
  rel="$(printf '%s' "$2" | tr ':' '/')"
  for f in "$1/agents/$rel.agent.md" "$1/agents/$rel.md"; do
    if [ -f "$f" ]; then fm="$(frontmatter_name "$f")"; [ -n "$fm" ] && { printf '%s' "$fm"; return; }; fi
  done
  printf '%s' "$2"
}

installs_for() { # installs_for <client> -> the calling client's own installs first (same plugin, different versions)
  case "$1" in *copilot*) copilot_installs; claude_installs ;; *) claude_installs; copilot_installs ;; esac
}

resolve_item() { # resolve_item <plugin> <name> <kind> <cwd> [client] -> plugin|kind|version|marketplace|found(1/0)|canonical-name
  local plugin="$1" name="$2" kind="$3" cwd="$4" client="${5:-}" root k id p m v s pp ip canon
  if [ -z "$plugin" ]; then
    for root in ${cwd:+"$cwd/.claude"} "$(claude_home)" "$(copilot_home)"; do
      k="$(item_kind "$root" "$name")"
      if [ -n "$k" ]; then
        [ "$kind" = "agent" ] && k="agent"
        canon="$name"; [ "$k" = "agent" ] && canon="$(agent_canonical "$root" "$name")"
        printf '|%s|||1|%s\n' "$k" "$canon"; return
      fi
    done
  fi
  local best=""
  while IFS='|' read -r id p m v s pp ip; do
    [ -z "$p" ] && continue
    if [ -n "$plugin" ] && [ "$p" != "$plugin" ]; then continue; fi
    k="$(item_kind "$ip" "$name")"
    if [ -n "$k" ]; then
      [ "$kind" = "agent" ] && k="agent"
      canon="$name"; [ "$k" = "agent" ] && canon="$(agent_canonical "$ip" "$name")"
      printf '%s|%s|%s|%s|1|%s\n' "$p" "$k" "$v" "$m" "$canon"; return
    fi
    [ -n "$plugin" ] && [ -z "$best" ] && best="$p|$kind|$v|$m|1|$name"
  done < <(installs_for "$client")
  if [ -n "$best" ]; then printf '%s\n' "$best"
  elif [ -n "$plugin" ]; then printf '%s|%s|||1|%s\n' "$plugin" "$kind" "$name"
  else printf '|%s|||0|%s\n' "$kind" "$name"
  fi
}
