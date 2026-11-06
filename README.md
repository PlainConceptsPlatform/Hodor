# Hodor: Company AI Hooks

Corporate hooks for VS Code (Copilot Chat), GitHub Copilot CLI and Claude Code.

**Policy = warn, never block (default)**: any finding (including **critical** ones: real secrets such as AWS/GCP/Azure keys, GitHub/Stripe tokens, private keys, credit cards) shows the user a non-blocking **warning** and the request continues. Blocking can be re-enabled via `policy.blockSeverity` (`warning` default = warn-only, `critical`, or `high`; `none` is accepted as an alias of `warning`).

Layers: `policy` (blocks/warns when the prompt violates the company AI policy), `usage` (skill/agent/command usage), `inventory` (what each user has installed).
Telemetry: OTel log events (`pc.ai.skill_usage`, `pc.ai.inventory`, `pc.ai.policy_warning`, `pc.ai.policy_block`, `pc.ai.hook_issue`, `pc.ai.selftest`) → OTel Collector → App Insights. The hook never waits for the network: events are queued on disk and a detached worker sends them (see [Sending telemetry](#sending-telemetry)).

Skill/agent/command telemetry covers **all** usage (not only Plain Concepts) and classifies each by the **plugin namespace** of the invocation name (`plugin:skill`, `plugin:agent`):

| `pc.source` | Condition | Example |
|---|---|---|
| `plainconcepts` | plugin starts with `skills.orgPluginPrefix` (default `pc-`) | `pc-ai:debugger` |
| `plugin` | any other plugin namespace | `anthropic-skills:docx` |
| `personal` | no namespace (user/project/built-in skill) | `my-local-skill` |

No maintained catalog is required. Classification is derived from the name at runtime, and enriched with what is installed locally (kind, version, marketplace).

### What each event carries

Every event: `pc.agent` (client: `claude-code` / `copilot`), `pc.user` (the person, always an email: `identity.email` → Claude account email (`~/.claude.json`) → `git config --global user.email` → Windows UPN (`whoami /upn`) → `USERNAME@local`), `pc.account` + `pc.account_type` (account of the tool that raised the event: `claude` = Claude account email, `github` = Copilot CLI GitHub login from `~/.copilot/config.json` → `lastLoggedInUser`; empty when unknown, e.g. Claude with an API key or Copilot only in VS Code), `pc.folder` (folder name of the session `cwd`), `pc.project` (git `org/repo` from the `origin` remote of the session `cwd`, empty when there is none; both hashed with `telemetry.projectMode=hash`), `pc.session_id`, `pc.hooks_version`.

| Event | When | Specific attributes |
|---|---|---|
| `pc.ai.skill_usage` | Skill / Agent (`Task`) tool call, `/plugin:name` in the prompt, a bare `/name` at the start of the prompt **when installed locally**, or (opt-in) reading a skill/agent `.md` | `pc.skill` (canonical: agents by their frontmatter `name`, the same from Claude Code and Copilot), `pc.skill_raw` (name as invoked, e.g. `risks-analyzer` from Copilot), `pc.plugin`, `pc.source`, `pc.kind` (`skill`/`agent`/`command`), `pc.via` (`tool`/`prompt`/`file_read`), `pc.plugin_version`, `pc.marketplace` |
| `pc.ai.inventory` | `SessionStart`, at most every `inventory.intervalHours` (720 = 30 days) or when the installed set changes; one event per plugin install + one per client for personal items, same `pc.inventory_id` | `pc.client`, `pc.plugin`, `pc.plugin_version`, `pc.marketplace`, `pc.marketplace_repo`, `pc.scope`, `pc.scope_project`, `pc.enabled`, `pc.install_ok`, `pc.source`, `pc.{skills,agents,commands}_count`, `pc.skills` / `pc.agents` / `pc.commands` (name lists) |
| `pc.ai.policy_warning` / `pc.ai.policy_block` | Prompt with a policy finding (warned / blocked) | `pc.rule`, `pc.severity`, `pc.action`, `pc.evidence` (redacted) |
| `pc.ai.hook_issue` | Hook failure, or records lost because the offline queue was full | `pc.error`, `pc.dropped` |
| `pc.ai.selftest` | `dispatch -Event selftest` | `pc.selftest` |

Severity (`severityText` / `severityNumber`): `skill_usage`, `inventory`, `selftest` → `INFO` (9); `policy_warning` → `WARN` (13); `policy_block`, `hook_issue` → `ERROR` (17). Resource attributes: `service.name=pc-ai-hooks`, `service.version`, `os.type`, `host.name`.

The same skill in the same session within `telemetry.dedupeSeconds` (120 s) counts once (e.g. `/pc-x:y` typed + the Skill tool call that follows). Commands are recognized by their file (`commands/<a>/<b>.md` → `a:b`), so built-ins like `/clear` are never counted.

## Sending telemetry

| Setting (`otel.*`) | Default | Meaning |
|---|---|---|
| `endpoint` | `""` | OTLP/HTTP collector (`/v1/logs` is appended). Empty = only the local queue |
| `background` | `true` | The hook only appends to `logs/telemetry-queue.jsonl` and starts a hidden, detached `dispatch -Event flush` worker. `false` = send inside the hook (3 s timeout), queue on failure |
| `flushBatchSize` | `200` | Records per request when flushing. A sent batch is removed; on the first failure the rest stays in `telemetry-queue.sending-*.jsonl` and is retried first |
| `retryMinutes` | `5` | With nothing new to send, any hook restarts the worker when a queue is waiting and the last attempt is older than this |
| `queueMaxSizeMB` | `2` | Queue cap (`.jsonl` → `.jsonl.1` → dropped). Dropped records are counted and reported as `pc.ai.hook_issue` with `pc.dropped` |
| `headers` | `{}` | Extra HTTP headers, e.g. `{"Authorization": "Bearer <token>"}` (`install-local.ps1 -OtelToken`). Stored in clear text: use an ingest-only token. bash passes them to curl through a private config file (never on the command line); needs `jq` |

- `SessionStart` hands the inventory scan to a worker too, so the session starts immediately.
- Only one flush runs at a time (`logs/flush.lock`, stale after 2 min). Worker state: `logs/state-flush.json` (`lastAttempt`, `lastSuccess`, `lastError`, `lastStatus`, `lastSent`).
- Manual commands (no stdin needed):

```powershell
powershell -NoProfile -File <install>\dispatch.ps1 -Event selftest   # sends pc.ai.selftest synchronously, prints {ok,status,ms,queue,flush...}; exit 1 on failure
powershell -NoProfile -File <install>\dispatch.ps1 -Event flush      # flush the queue now, prints {ok,sent,pending,...}
```

```bash
./dispatch.sh selftest
./dispatch.sh flush
```

Collector with bearer auth (local): `infra/local/docker-compose.auth.yml` overlay (`bearertokenauth`, token from `HODOR_INGEST_TOKEN` in `infra/local/.env`).

## Structure

```
ai-hooks/
├── VERSION                        # MAJOR.MINOR base (e.g. 1.2); patch is derived from git per commit
├── build-info.json               # stamped at install/package time (gitignored): full version + commit + date
├── dispatch.ps1 / dispatch.sh     # single entry point: dispatch -Event <event> -Agent <agent>
├── lib/                           # common, logrotate, otel, plugins (installed-plugin index) (PS + bash)
├── layers/
│   ├── policy/                    # scan-prompt + patterns.d/*.txt (NAME|SEVERITY|REGEX)
│   ├── usage/                     # usage: captures ALL skills, agents & commands; tags Plain Concepts (pc- plugin) vs plugin vs personal
│   └── inventory/                 # inventory: installed plugins (Claude Code + Copilot) and personal skills/agents/commands
├── config/
│   ├── settings.json              # OTel endpoint, log rotation, identity, policy.blockSeverity, skills.orgPluginPrefix
│   └── allowlist.txt              # approved false positives
├── adapters/
│   ├── copilot/company-hooks.json # → ~/.copilot/hooks/ (VS Code + Copilot CLI)
│   └── claude/hooks-fragment.json # → managed settings or ~/.claude/settings.json
├── tools/
│   ├── hodor-version.ps1 / .sh    # doctor: version + paths + hook wiring
│   ├── stamp-build-info.ps1       # computes build-info.json from git (shared: install + CI)
│   └── dashboard.html             # static, offline telemetry dashboard (drag & drop a log file)
├── tests/
│   ├── cases/                     # shared fixtures (cmd, payload.json, expect, settings.json?)
│   └── run.ps1 / run.sh           # dependency-free regression suite (both dispatchers)
├── .github/workflows/tests.yml    # CI: runs the suite on push/PR (Windows + Linux)
└── install-local.ps1              # local test installation (Windows)
```

## Versioning & checking the installed version

The version updates **on every commit**, derived from git, with no manual bumps:

- `VERSION` holds only the base `MAJOR.MINOR` (e.g. `1.2`).
- The **full version** is `MAJOR.MINOR.<commit-count>+g<short-sha>` (e.g. `1.2.42+gabc1234`); the patch is `git rev-list --count HEAD`, so it increments per commit.
- `build-info.json` (git-ignored) is stamped at install/package time by `tools/stamp-build-info.ps1` and carries the resolved `version`, `commit`, `commitCount`, `buildDate`. At runtime the version resolves from `build-info.json` → live git (dev checkout) → fallback.
- The full version is attached to **every** telemetry event (`pc.hooks_version`) and written into each `security.jsonl` record, so a report can be traced to exact code.

When something misbehaves, run the **doctor**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\PlainConcepts\ai-hooks\tools\hodor-version.ps1"
# or just the identifier:
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1" -Event version
```

It prints the version, install/config/log paths, whether the Claude Code and Copilot hooks are wired, and the last few hook errors (plus a JSON line to paste into a report). On macOS/Linux use `tools/hodor-version.sh` / `./dispatch.sh version`.

> **Future CI contract:** the packaging workflow must check out with full history (`fetch-depth: 0`, needed for `rev-list --count`), run `tools/stamp-build-info.ps1` before packaging the `.intunewin`, and publish to Intune via Microsoft Graph. `build-info.json` (or `HKLM\SOFTWARE\PlainConcepts\AIHooks\Version`) backs the Intune detection rule.

## Pilot installation (Windows, one script)

For pilot testers: `pilot/Install-Hodor.ps1` clones this repo to `%USERPROFILE%\Hodor`, resolves the corporate UPN (`System32\whoami.exe /upn`), runs `install-local.ps1` against the Atlas endpoint with the ingest token (asked interactively, or `-Token` / `$env:HODOR_TOKEN`), enables `chat.useHooks` in VS Code (backup `settings.json.hodor.bak`; skipped if the file has comments) and runs the selftest.

```powershell
irm https://raw.githubusercontent.com/PlainConceptsPlatform/Hodor/main/pilot/Install-Hodor.ps1 -OutFile Install-Hodor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Hodor.ps1
```

`pilot/Uninstall-Hodor.ps1` reverts it: stops background workers, removes only Hodor's hooks from `~/.claude/settings.json` (other hooks and settings are kept; backup `.hodor-uninstall.bak`), deletes the Copilot hook file, the install folder and the repo copy (`-KeepRepo`, `-KeepLogs` zips the logs to the Desktop), and turns `chat.useHooks` back off if the installer enabled it.

## Local installation (Windows)

```powershell
# As Administrator (writes to C:\ProgramData):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1

# Without admin rights (recommended for local testing):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
```

It copies the scripts, installs `~/.copilot/hooks/company-hooks.json` (covers both VS Code and Copilot CLI) and adds the hooks to `~/.claude/settings.json` (with backup). A reinstall **keeps** the values of the installed `config/settings.json`. Optional parameters set them in one go:

```powershell
.\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks" `
  -OtelEndpoint http://localhost:4318 -IdentityEmail me@plainconcepts.com -IdentityMode email `
  -TrackFileReads   # opt-in: also count skills/agents loaded by reading their .md (hooks Read|Bash)
```

Afterwards: enable `chat.useHooks` in VS Code (preview), and confirm `policy.blockSeverity` and `skills.orgPluginPrefix`.

## Tests (regression suite)

Dependency-free suite: shared fixtures in `tests/cases/` drive **both** dispatchers, so PowerShell and bash behavior stay in lock-step. Runs in isolation (temp log dir + temp settings via the `AIHOOKS_SETTINGS` override), so it never touches your real logs. Exits non-zero on any failure.

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```
```bash
# macOS / Linux / Git Bash
bash tests/run.sh
```

Coverage: block-on-critical vs warn (and the `policy.blockSeverity` threshold), evidence redaction / no prompt leak, skill/agent classification by plugin namespace, payload normalization across the 3 agents, and the version command. CI runs both on every push/PR (`.github/workflows/tests.yml`). Add a regression test by dropping a new folder in `tests/cases/` (`cmd`, `payload.json`, `expect`, optional `settings.json`).

## Quick manual check without an IDE

```powershell
# CRITICAL -> WARNS by default (policy.blockSeverity=warning): prints {"systemMessage":...}, exit code 0
# (with policy.blockSeverity=critical: {"decision":"block",...} on stdout, the reason on stderr, exit code 2)
'{"prompt":"upload this with token ghp_0123456789abcdefghijklmnopqrstuvwxyz12"}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1 -Event UserPromptSubmit -Agent claude-code
"exit=$LASTEXITCODE"

# MEDIUM -> WARNS (not blocked): prints {"systemMessage":"[...WARNING]..."}, exit code 0
'{"prompt":"call me at +34600111222"}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1 -Event UserPromptSubmit -Agent claude-code

# Clean prompt: prints nothing, exit code 0
'{"prompt":"refactor this function"}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1 -Event UserPromptSubmit -Agent claude-code

# Plain Concepts skill (Skill tool): queues pc.ai.skill_usage with source=plainconcepts
'{"tool_name":"Skill","tool_input":{"skill":"pc-ai:debugger"}}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1 -Event PreToolUse -Agent claude-code

# Subagent (Task tool): queues pc.ai.skill_usage with kind=agent
'{"tool_name":"Task","tool_input":{"subagent_type":"pc-quality:reviewer"}}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1 -Event PreToolUse -Agent claude-code
```

Logs (circular rotation, 5 MB × 3, configurable): `%LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\`
(`security.jsonl`, with `event: policy_block`/`policy_warning` and `action`; `hooks-error.jsonl`; `telemetry-queue.jsonl` while not yet sent).

## Telemetry dashboard

The JSONL logs are hard to read by hand. `tools/dashboard.html` is a **static, offline** dashboard: no server, no dependencies, nothing leaves the page. Open it in a browser and **drag & drop** (or pick) `telemetry-queue.jsonl` (optionally also `security.jsonl` / `hooks-error.jsonl`):

```
start "" "%LOCALAPPDATA%\PlainConcepts\ai-hooks\tools\dashboard.html"
# then drop the log from %LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\
```

It shows: **policy findings grouped by severity** (critical/high/medium, with a per-rule block/warn breakdown) and **skills & agents by usage** (every skill/agent sorted most-used → least, tagged by plugin and source), plus a hook-errors panel. It also accepts the collector's file export (`infra/local/data/telemetry.jsonl`, one `resourceLogs` envelope per line) — useful now that the local queue is emptied by the background worker — and shows an **Installed** panel from `pc.ai.inventory` (latest snapshot per user: plugins, versions in the field, item counts, broken installs). It parses both queue formats (legacy PowerShell object-attrs and OTLP array-attrs) and tolerates mixed/old schemas, BOM and malformed lines. Large files load with a progress bar and non-blocking (batched) parsing. `tools/dashboard-sample.jsonl` is a small demo file you can drop to see it in action.

### Confirming the real payload format (`HODOR_DEBUG`)

The exact `tool_input` field of the Skill tool (and whether it carries the `plugin:` namespace) is not documented. To confirm what your client actually sends, set the env var and reproduce a real invocation. Every raw payload is dumped to `logs\payloads-debug.jsonl`:

```powershell
$env:HODOR_DEBUG = "1"   # then restart Claude Code / VS Code and invoke a pc- skill or agent
```

Adjust the field parsing in `layers/usage` if the observed format differs.

## Behavior per platform

| | Blocks critical | Warns high/medium | Notes |
|---|---|---|---|
| Claude Code | Yes (`decision:block` + `exit 2`) | Yes (`systemMessage`) | In production: hooks via managed settings |
| VS Code | Yes (honors `exit 2` / `decision:block`) | Yes (`systemMessage`) | Requires `chat.useHooks`; agent hooks are in preview |
| Copilot CLI | No (ignores `userPromptSubmitted` output) | No | Finding is still logged + sent to telemetry |

The hook emits all block signals (stderr message + `{"decision":"block"}` on stdout + `exit 2`); each platform honors the one it understands. Copilot CLI cannot be blocked at prompt time (known limitation).

## Testing on macOS/Linux

```bash
chmod +x dispatch.sh layers/policy/scan-prompt.sh layers/usage/usage.sh
# CRITICAL -> warns (exit 0; blocks with exit 2 only if policy.blockSeverity=critical)
echo '{"prompt":"token ghp_0123456789abcdefghijklmnopqrstuvwxyz12"}' | ./dispatch.sh UserPromptSubmit claude-code; echo "exit=$?"
# Skill usage
echo '{"tool_name":"Skill","tool_input":{"skill":"pc-ai:debugger"}}' | ./dispatch.sh PreToolUse claude-code
```

Requires bash + curl; `jq` recommended. Logs in `~/.local/state/plainconcepts/ai-hooks/`.

## Production

See `plan-company-hooks-v1.md`: private repo → CI builds the `.intunewin` → Intune (Win32 + remediation). Claude Code moves to managed settings (`HKLM\SOFTWARE\Policies\ClaudeCode`); VS Code enforces `ChatHooks` via ADMX policy.
