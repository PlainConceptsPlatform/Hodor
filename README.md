# Hodor — Company AI Hooks

Corporate hooks for VS Code (Copilot Chat), GitHub Copilot CLI and Claude Code.

**Policy = block on critical**: a prompt with a **critical** finding (real secrets — AWS/GCP/Azure keys, GitHub/Stripe tokens, private keys, credit cards) is **blocked before reaching the model**. `high`/`medium` findings stay as a non-blocking **warning** (the request continues). The threshold is configurable via `policy.blockSeverity` (`critical` default · `high` · `none` = warn-only).

Layers: `10-policy` (blocks/warns when the prompt violates the company AI policy), `30-skills` (skill/agent usage).
Telemetry: 3 OTel events (`pc.ai.policy_warning`, `pc.ai.hook_issue`, `pc.ai.skill_usage`) → App Insights; without network/endpoint they are queued on disk and retried on `sessionEnd`.

Skill/agent telemetry covers **all** usage (not only Plain Concepts) and classifies each by the **plugin namespace** of the invocation name (`plugin:skill`, `plugin:agent`):

| `pc.source` | Condition | Example |
|---|---|---|
| `plainconcepts` | plugin starts with `skills.orgPluginPrefix` (default `pc-`) | `pc-ai:debugger` |
| `plugin` | any other plugin namespace | `anthropic-skills:docx` |
| `personal` | no namespace (user/project/built-in skill) | `my-local-skill` |

No maintained catalog is required — classification is derived from the name at runtime.

## Structure

```
ai-hooks/
├── VERSION                        # MAJOR.MINOR base (e.g. 1.2); patch is derived from git per commit
├── build-info.json               # stamped at install/package time (gitignored): full version + commit + date
├── dispatch.ps1 / dispatch.sh     # single entry point: dispatch -Event <event> -Agent <agent>
├── lib/                           # common, logrotate, otel (PS + bash)
├── layers/
│   ├── 10-policy/                 # scan-prompt + patterns.d/*.txt (NAME|SEVERITY|REGEX)
│   └── 30-skills/                 # skill-usage (namespace classification)
├── config/
│   ├── settings.json              # OTel endpoint, log rotation, identity, policy.blockSeverity, skills.orgPluginPrefix
│   └── allowlist.txt              # approved false positives
├── adapters/
│   ├── copilot/company-hooks.json # → ~/.copilot/hooks/ (VS Code + Copilot CLI)
│   └── claude/hooks-fragment.json # → managed settings or ~/.claude/settings.json
├── tools/
│   ├── hodor-version.ps1 / .sh    # doctor: version + paths + hook wiring
│   └── stamp-build-info.ps1       # computes build-info.json from git (shared: install + CI)
├── tests/
│   ├── cases/                     # shared fixtures (cmd, payload.json, expect, settings.json?)
│   └── run.ps1 / run.sh           # dependency-free regression suite (both dispatchers)
├── .github/workflows/tests.yml    # CI: runs the suite on push/PR (Windows + Linux)
└── install-local.ps1              # local test installation (Windows)
```

## Versioning & checking the installed version

The version updates **on every commit**, derived from git — no manual bumps:

- `VERSION` holds only the base `MAJOR.MINOR` (e.g. `1.2`).
- The **full version** is `MAJOR.MINOR.<commit-count>+g<short-sha>` (e.g. `1.2.42+gabc1234`); the patch is `git rev-list --count HEAD`, so it increments per commit.
- `build-info.json` (git-ignored) is stamped at install/package time by `tools/stamp-build-info.ps1` and carries the resolved `version`, `commit`, `commitCount`, `buildDate`. At runtime the version resolves from `build-info.json` → live git (dev checkout) → fallback.
- The full version is attached to **every** telemetry event (`pc.hooks_version`) and written into each `security.jsonl` record — so a report can be traced to exact code.

When something misbehaves, run the **doctor**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\PlainConcepts\ai-hooks\tools\hodor-version.ps1"
# or just the identifier:
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1" -Event version
```

It prints the version, install/config/log paths, whether the Claude Code and Copilot hooks are wired, and the last few hook errors (plus a JSON line to paste into a report). On macOS/Linux use `tools/hodor-version.sh` / `./dispatch.sh version`.

> **Future CI contract:** the packaging workflow must check out with full history (`fetch-depth: 0`, needed for `rev-list --count`), run `tools/stamp-build-info.ps1` before packaging the `.intunewin`, and publish to Intune via Microsoft Graph. `build-info.json` (or `HKLM\SOFTWARE\PlainConcepts\AIHooks\Version`) backs the Intune detection rule.

## Local installation (Windows)

```powershell
# As Administrator (writes to C:\ProgramData):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1

# Without admin rights (recommended for local testing):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
```

It copies the scripts, installs `~/.copilot/hooks/company-hooks.json` (covers both VS Code and Copilot CLI) and adds the hooks to `~/.claude/settings.json` (with backup). Afterwards: enable `chat.useHooks` in VS Code (preview), fill in `identity.email` in `config/settings.json`, and confirm `policy.blockSeverity` and `skills.orgPluginPrefix`.

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
# CRITICAL -> BLOCKS: prints {"decision":"block",...} on stdout, the reason on stderr, exit code 2
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
(`security.jsonl` — with `event: policy_block`/`policy_warning` and `action`; `hooks-error.jsonl`; `telemetry-queue.jsonl`).

### Confirming the real payload format (`HODOR_DEBUG`)

The exact `tool_input` field of the Skill tool (and whether it carries the `plugin:` namespace) is not documented. To confirm what your client actually sends, set the env var and reproduce a real invocation — every raw payload is dumped to `logs\payloads-debug.jsonl`:

```powershell
$env:HODOR_DEBUG = "1"   # then restart Claude Code / VS Code and invoke a pc- skill or agent
```

Adjust the field parsing in `layers/30-skills` if the observed format differs.

## Behavior per platform

| | Blocks critical | Warns high/medium | Notes |
|---|---|---|---|
| Claude Code | Yes (`decision:block` + `exit 2`) | Yes (`systemMessage`) | In production: hooks via managed settings |
| VS Code | Yes (honors `exit 2` / `decision:block`) | Yes (`systemMessage`) | Requires `chat.useHooks`; agent hooks are in preview |
| Copilot CLI | No (ignores `userPromptSubmitted` output) | No | Finding is still logged + sent to telemetry |

The hook emits all block signals (stderr message + `{"decision":"block"}` on stdout + `exit 2`); each platform honors the one it understands. Copilot CLI cannot be blocked at prompt time (known limitation).

## Testing on macOS/Linux

```bash
chmod +x dispatch.sh layers/10-policy/scan-prompt.sh layers/30-skills/skill-usage.sh
# CRITICAL -> blocks (exit 2)
echo '{"prompt":"token ghp_0123456789abcdefghijklmnopqrstuvwxyz12"}' | ./dispatch.sh UserPromptSubmit claude-code; echo "exit=$?"
# Skill usage
echo '{"tool_name":"Skill","tool_input":{"skill":"pc-ai:debugger"}}' | ./dispatch.sh PreToolUse claude-code
```

Requires bash + curl; `jq` recommended. Logs in `~/.local/state/plainconcepts/ai-hooks/`.

## Production

See `plan-company-hooks-v1.md`: private repo → CI builds the `.intunewin` → Intune (Win32 + remediation). Claude Code moves to managed settings (`HKLM\SOFTWARE\Policies\ClaudeCode`); VS Code enforces `ChatHooks` via ADMX policy.
