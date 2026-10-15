# Hodor: tasks backlog (telemetry operability)

Goal: reliable skill / agent / command usage telemetry (per project and user) → OTel Collector → Application Insights. Local-first: infra runs with docker compose (`infra/local/`); production deployment (Azure + Intune) in `docs/deployment.md`.

Done: C0, A1–A4, A6–A8, E1 (phases 1–2); B1–B7, D2–D4, E4 (phase 3, 2026-10-14); C4 (2026-10-15). Next: C5 (KQL), D1, E2/E3.

Pending decisions (implemented as settings; defaults below until decided):
- [ ] **Project**: repo name in clear text or hashed? → `telemetry.projectMode` (`name` default | `hash`).
- [ ] **User**: hash or real email? (check with HR/GDPR — the plan promises anonymization) → `identity.mode` (`hash` default | `email`).

---

## C0 — Local infra to test the current version (prerequisite)

- [x] `infra/local/docker-compose.yml`: OTel Collector (contrib) + Aspire Dashboard (local UI).
- [x] `infra/local/otel-collector.yaml`: `otlp` HTTP receiver → `debug` + `file` + Aspire exporters.
- [x] `infra/local/otel-collector.appinsights.yaml` + `docker-compose.appinsights.yml`: optional overlay that adds the `azuremonitor` exporter (dev App Insights connection string in `.env`).
- [x] `infra/local/smoke.ps1`: sends events with the current dispatcher (isolated settings) and checks they reach the collector.
- [x] Validate end to end on a developer machine (2026-10-01: smoke OK — direct send, offline queue + SessionEnd flush, all events in the file exporter). Confirms B2: every record arrives as `SeverityText: WARN` with no `severityNumber`.
- [ ] Validate the App Insights overlay against a real dev App Insights (`customEvents` + `traces`, see C4). Verified so far only against a fake ingestion endpoint.

## A — Correct capture (hook) — Phase 1, implemented 2026-10-14

- [x] **A1. Capture agents with `Agent` as well as `Task`** — matcher `Task|Agent`, dispatcher regex `^([Tt]ask|[Aa]gent)$`. Cases 11 + 14.
- [x] **A2. Commands (`kind=command`)** — resolved against what is installed instead of a built-in list: a name is a `command` when the plugin (or `~/.claude`, `<cwd>/.claude`) has `commands/<a>/<b>.md`. A bare `/name` counts only at the start of the prompt AND when installed locally (so `/clear`, `/usr/bin/...` never match); a bare name also resolves to the plugin exposing it. Cases 15–18.
  - Confirmed in a real transcript: `UserPromptSubmit` receives the raw `/plugin:name args` text.
- [x] **A3. Project and session context** — `pc.project` (git origin of payload `cwd` → `org/repo`, fallback folder name, `unknown`), `pc.session_id`. Setting `telemetry.projectMode`. Case 21.
- [x] **A4. User identity** — `identity.mode`: `hash` (default, only `pc.user_hash`) | `email` (also `pc.user`: `identity.email` → `git config user.email` → `USERNAME@local`). Cases 19–20.
- [x] **A5. Copilot payloads** — `toolArgs` as a JSON string is parsed; `cwd` / `sessionId` normalized (case 22). Confirmed live (2026-10-14): Copilot CLI calls the agent tool with the agent FILE name (`risks-analyzer`) while Claude Code uses the frontmatter name (`pc.presales.risks-analyzer`); `pc.skill` is now canonical (frontmatter name) and `pc.skill_raw` keeps the invoked name (case 30).
  - Fixed 2026-10-15: Copilot CLI expands `/plugin:skill args` before `userPromptSubmitted`, so the hook gets `The user explicitly invoked the "/plugin:skill" skill. ...` + the whole SKILL.md (and no `preToolUse`, the skill is injected directly). The `(^|\s)/plugin:name` scan missed it (quote before the slash). The usage layer now recognizes that preamble, counts only the named skill and skips the embedded skill text, which may mention other `/plugin:name` tokens (case 31).
  - Fixed 2026-10-14: `install-local.ps1` wrote `~/.copilot/hooks/company-hooks.json` with a UTF-8 BOM (`Set-Content -Encoding UTF8` in Windows PowerShell), so Copilot CLI rejected the whole file ("Invalid JSON: expected value at line 1 column 1") and **no Copilot hook ever ran** on Windows. Now written without BOM; `tests/run.ps1` runs the real installer (isolated `USERPROFILE`/`LOCALAPPDATA`) and checks every JSON it writes (no BOM, valid, wired to the install).
- [x] **A6. Dedupe** — a `/plugin:skill` prompt followed by the Skill tool call (or a repeated hook) counted twice. Same session + plugin + skill inside `telemetry.dedupeSeconds` (120 s) = 1 use. State: `logs/state-dedupe.*`.
- [x] **A7. Enrichment** — every `skill_usage` carries `pc.via` (`tool` | `prompt` | `file_read`), `pc.plugin_version`, `pc.marketplace` (the calling client's install first: Claude Code and Copilot may have different versions).
- [x] **A8. File-read heuristic (opt-in)** — `usage.trackFileReads` + `install-local.ps1 -TrackFileReads` (adds a `Read|Bash` PreToolUse matcher). Counts skills/agents/commands loaded by reading their `.md` (e.g. the model `cat`-ing `discovery.agent.md`), tagged `pc.via=file_read`. Off by default on Claude Code (it adds a hook run to every Read/Bash call); always on for Copilot, whose preToolUse already runs for every tool. Reads of a file inside the current workspace (cwd) are ignored, so plugin authors editing their own files are not counted. Also parses the batched preToolUse payload of the Copilot agents window (`toolCalls[{name, args}]`), where an intent-routed agent ("genera clarification questions") shows up as the model `view`-ing its `.agent.md`. Cases 23–25, 32–34.

## E — Inventory (what each user has installed) — Phase 2, implemented 2026-10-14

- [x] **E1. `pc.ai.inventory` on `SessionStart`** (Claude Code `SessionStart`, Copilot `sessionStart`). One event per plugin install + one per client for personal items, all sharing `pc.inventory_id`, sent in ONE request.
  - Sources: `~/.claude/plugins/installed_plugins.json` (+ `known_marketplaces.json` for `pc.marketplace_repo`, `enabledPlugins` in user/project settings for `pc.enabled`), `~/.copilot/installed-plugins/**/plugin.json`, `~/.claude|.copilot/{skills,agents,commands}`.
  - Per record: `pc.client`, `pc.plugin`, `pc.plugin_version`, `pc.marketplace`, `pc.marketplace_repo`, `pc.scope`, `pc.scope_project`, `pc.enabled`, `pc.install_ok` (install folder exists), `pc.source`, `pc.{skills,agents,commands}_count` and the name lists (invocation names, capped at 4000 chars).
  - Throttle: resent only every `inventory.intervalHours` (24) or when the fingerprint changes. Disable with `inventory.enabled=false`. Cases 26–27 + multi-run checks.
  - bash: needs `jq` (prints nothing without it).
- [ ] **E2. Catalog** — CI of `PlainConcepts/skills` publishes `catalog.json` (every skill/agent/command per plugin) so reports can show items with 0 uses.
- [ ] **E3. Reports** — KQL/Workbook: adoption (installed vs used), unused items, versions in the field, by project/user (see C5).
- [x] **E4. SessionStart latency** — the first run after boot took ~6 s on Windows (cold file cache, AV); ~1 s warm. Done with B1: `SessionStart` saves its payload to `logs/pending-inventory.json` and a detached `dispatch -Event inventory` worker scans, sends and flushes.

## B — Telemetry sending

- [x] **B1. Background sending** — `otel.background` (default `true`): `Send-OtelEvents` / `otel_send_records` only append to the queue; at the end of the dispatch a hidden, detached `dispatch -Event flush` worker sends it (`Start-Process -WindowStyle Hidden` / `setsid|nohup … &`). Lock `logs/flush.lock` (bash `flush.lock.d`), stale after 2 min. `false` = previous synchronous send.
  - Measured (Windows, collector unreachable): hook 4.4 s synchronous → same as the no-endpoint baseline in background (the worker start costs ~0.1–0.4 s). Verified the hook returns while the worker is still running (stdout pipe not inherited).
- [x] **B2. Correct severity** — `skill_usage`/`inventory`/`selftest` → `INFO` 9, `policy_warning` → `WARN` 13, `policy_block`/`hook_issue` → `ERROR` 17; both `severityText` and `severityNumber`.
  - Decided: blocks are a separate `pc.ai.policy_block` event (still with `pc.action=block`).
- [x] **B3. Same queue schema PS/bash** — one complete OTLP logRecord per line (time, severity, body, attributes). The PS flush converts legacy `{ts,name,attributes}` lines (original timestamp kept); the dashboard reads both.
- [x] **B4. Robust flush** — batches of `otel.flushBatchSize` (200); the queue is moved atomically to `telemetry-queue.sending-*.jsonl` before sending; a sent batch is removed, on the first failure the rest stays and is retried first (also after a crashed worker). Idle retry: any hook restarts the worker when a queue waits and the last attempt is older than `otel.retryMinutes` (5). Rotation drops are counted (`state-dropped.txt`) and reported as `pc.ai.hook_issue` + `pc.dropped`. State: `logs/state-flush.json`. Payload goes through a temp file (`curl --data-binary @file`).
- [x] **B5. Headers / auth** — `otel.headers` (`Invoke-WebRequest -Headers`; bash: `curl -K <private config file>`, never on the command line; needs `jq`). `install-local.ps1 -OtelToken`. Collector overlay `infra/local/docker-compose.auth.yml` + `otel-collector.auth.yaml` (`bearertokenauth`, `HODOR_INGEST_TOKEN`). Verified: no/wrong token → 401, right token → 200 (PS and bash).
- [x] **B6. Resource attributes** — `service.name`, `service.version`, `os.type`, `host.name` (hashed unless `identity.mode=email`). `deployment.environment` not added (no setting yet).
- [x] **B7. Tests** — mock collector (`tests/mock-otlp.ps1` HttpListener; `tests/mock-otlp.py` for bash, skipped without python3+jq): selftest ok/down, headers, severity + resource, 450 records in 3 batches, partial failure + retry, legacy line, lock (fresh/stale), dropped counter, background worker delivery (prompt + SessionStart inventory), latency with an unreachable endpoint.

## C — Collector / App Insights (beyond C0)

- [x] **C4. App Insights mapping** (2026-10-15) — business events (`skill_usage`, `inventory`, `policy_warning`, `policy_block`) → `customEvents`; diagnostics (`hook_issue`, `selftest`) stay in `traces` (severity matters there). Done in the collector only, hooks unchanged: `transform/custom_events` sets `microsoft.custom_event.name` = body and copies `service.version`, `os.type`, `host.name` into the record (the exporter's custom-event path drops resource attributes and severity); `azuremonitor.custom_events_enabled: true` (needs collector ≥ 0.125; image bumped 0.120.0 → 0.130.0). Separate `logs/appinsights` pipeline, so the local file / Aspire are unchanged. Verified with a fake ingestion endpoint: 4 × `EventData` with the copied attributes, 2 × `MessageData` with severity; base smoke OK on 0.130.0. Note: custom events carry no `user_Id`/`session_Id`, so the App Insights Users/Funnels blades do not apply; use KQL on `pc.user_hash`.
- [ ] **C5. KQL queries** — `infra/queries/*.kql`: usage by skill/agent/command, by project, by user, policy findings by rule, hook issues by version.
- [ ] **C6. Privacy processor** — `attributes`/`transform` processor in the collector (e.g. drop `pc.evidence` if decided).

## D — Operability and diagnostics

- [ ] **D1. Doctor**: `hodor-version` shows endpoint configured + reachable, queue size, last successful flush, last send error.
- [x] **D2. `dispatch -Event flush`**: manual queue flush.
- [x] **D3. `dispatch -Event selftest`**: synthetic `pc.ai.selftest` event end to end.
- [x] **D4. Installer**: `install-local.ps1 -OtelEndpoint -OtelToken -IdentityMode` (no manual `settings.json` editing).
- [ ] **D5. Manual battery**: extend `docs/manual-test-battery.md` with the E2E test (compose → hook → collector → Aspire/App Insights).
