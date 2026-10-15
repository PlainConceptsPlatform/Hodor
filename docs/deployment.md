# Hodor: production deployment (Azure + Intune)

What has to exist in Azure, GitHub and Intune so the hooks run on every developer machine and their telemetry lands in Application Insights. The local stack (`infra/local/`) is for testing only and is not part of this.

Status legend: **[ready]** exists in this repo and is tested, **[todo]** still to build or decide.

## 1. Big picture

```
 GitHub (private repo)                    Intune                                  Developer machine
 ───────────────────                      ──────                                  ─────────────────
 main ──CI──> tests ──> stamp version     Win32 app (system)  ──────────────────> C:\ProgramData\PlainConcepts\ai-hooks\
          └─> .intunewin ──Graph API────> Per-user setup (user) ────────────────> ~/.copilot/hooks/company-hooks.json
                                          Claude managed settings ──────────────> hooks in Claude Code (not user-editable)
                                          VS Code policy ChatHooks ─────────────> hooks enabled in VS Code
                                          Remediation (daily, user) ────────────> repairs drift

 Developer machine                        Azure (rg-ai-hooks)
 ─────────────────                        ───────────────────
 hook ─> local queue ─> flush worker ───HTTPS OTLP/HTTP + Bearer───> OTel Collector (Container App)
                                                                      └─azuremonitor exporter─> Application Insights
                                                                                                 └─> Log Analytics workspace
```

Two independent tracks: **Azure** (the place telemetry goes) and **distribution** (getting the hooks onto machines). The hooks work without Azure (warn/block, local logs, queue); telemetry just accumulates in the on-disk queue (capped by `otel.queueMaxSizeMB`) until the endpoint exists.

## 2. Checklist

| # | Component | Where | Status |
|---|---|---|---|
| 1 | Resource group, Log Analytics workspace, Application Insights | Azure | [todo] (dev App Insights commands in `infra/local/README.md` §4) |
| 2 | Key Vault with ingest token + connection string | Azure | [todo] |
| 3 | OTel Collector on Azure Container Apps (HTTPS, bearer auth, azuremonitor exporter) | Azure | [todo] (config pieces exist locally: `otel-collector.auth.yaml`, `otel-collector.appinsights.yaml`) |
| 4 | Stable public endpoint (custom domain or Container Apps FQDN) | Azure / DNS | [todo] |
| 5 | Production values in `config/settings.json` (endpoint, token, salt) | Repo / CI secrets | [todo] |
| 6 | Intune installer `packaging/install.ps1` (`install-local.ps1` is explicitly not it) | Repo | [todo] |
| 7 | `packaging/build.ps1` → `.intunewin` | Repo | [todo] |
| 8 | Release workflow: test, stamp, package, publish via Graph | GitHub Actions | [todo] (`tests.yml` + `tools/stamp-build-info.ps1` are [ready]) |
| 9 | App registration / service principal for Graph publishing | Entra ID | [todo] |
| 10 | Intune Win32 app (detection rule, supersedence, rings) | Intune | [todo] |
| 11 | Per-user Copilot hook file | Intune | [todo] |
| 12 | Claude Code managed settings with the hooks | Intune | [todo] |
| 13 | VS Code `ChatHooks` policy | Intune (Settings Catalog / ADMX) | [todo] |
| 14 | Remediation script (drift repair) | Intune | [todo] |
| 15 | KQL queries, workbook | Azure | [todo] (task C5; table mapping C4 is [ready]) |

## 3. Azure

Everything in one resource group, e.g. `rg-ai-hooks` in `westeurope`.

### 3.1 Application Insights (workspace-based)

```bash
az group create -n rg-ai-hooks -l westeurope
az monitor log-analytics workspace create -g rg-ai-hooks -n law-ai-hooks -l westeurope
az extension add -n application-insights
az monitor app-insights component create --app appi-ai-hooks -g rg-ai-hooks -l westeurope --workspace law-ai-hooks
az monitor app-insights component show --app appi-ai-hooks -g rg-ai-hooks --query connectionString -o tsv
```

Decide before creating:

- **Retention** of the workspace (default 30 days). Usage trends need longer; set it on the workspace or on the `AppTraces` table.
- **Daily cap** on the workspace as a safety net against a runaway client.
- Tables (task C4): `skill_usage`, `inventory`, `policy_warning`, `policy_block` land in **`customEvents`**; `hook_issue` and `selftest` in **`traces`**. The `pc.*` attributes are in `customDimensions` in both. Retention and cost apply to `AppEvents` and `AppTraces` in the workspace.

### 3.2 Key Vault

`kv-ai-hooks` with:

| Secret | Used by |
|---|---|
| `appinsights-connection-string` | Collector (`APPLICATIONINSIGHTS_CONNECTION_STRING`) |
| `hodor-ingest-token` | Collector (`HODOR_INGEST_TOKEN`) and the packaging pipeline (baked into the installed `settings.json`) |
| `hodor-identity-salt` | Packaging pipeline (`identity.salt`; see §4.1) |

The Container App reads them through a **user-assigned managed identity** with the *Key Vault Secrets User* role.

### 3.3 OTel Collector on Azure Container Apps

Why a collector instead of sending straight to Azure Monitor: the hooks only speak plain OTLP/HTTP with a static header. Azure Monitor's native OTLP ingestion needs Entra ID auth, which a hook on every laptop cannot do cleanly. The collector also gives a single place to filter or anonymize (task C6).

Resources:

- Container Apps environment `cae-ai-hooks` (logs to `law-ai-hooks`).
- Container App `ca-otel-collector`:
  - Image `otel/opentelemetry-collector-contrib:0.130.0` (pinned, same as local; `custom_events_enabled` needs ≥ 0.125).
  - Ingress **external**, HTTPS only, target port `4318`. TLS is terminated by Container Apps; the collector itself listens on plain HTTP.
  - Health probe: HTTP `GET :13133/`.
  - Scale: min 1, max 3 replicas (1 is plenty; the clients batch 200 records per request and retry on their own).
  - Secrets from Key Vault: `APPLICATIONINSIGHTS_CONNECTION_STRING`, `HODOR_INGEST_TOKEN`.

Production collector config (only the azuremonitor exporter; no `debug`, `file` or Aspire). It is the local base + auth + App Insights overlays merged. The `transform/custom_events` processor routes business events to `customEvents` and copies the resource attributes that the exporter drops on that path (see `infra/local/otel-collector.appinsights.yaml`):

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  bearertokenauth:
    scheme: Bearer
    token: ${env:HODOR_INGEST_TOKEN}

receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
        auth:
          authenticator: bearertokenauth

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  batch: {}
  transform/custom_events:
    error_mode: ignore
    log_statements:
      - context: log
        conditions:
          - IsMatch(log.body, "^pc\\.ai\\.(skill_usage|inventory|policy_warning|policy_block)$")
        statements:
          - set(log.attributes["microsoft.custom_event.name"], log.body)
          - set(log.attributes["service.version"], resource.attributes["service.version"])
          - set(log.attributes["os.type"], resource.attributes["os.type"])
          - set(log.attributes["host.name"], resource.attributes["host.name"])

exporters:
  azuremonitor:
    connection_string: ${env:APPLICATIONINSIGHTS_CONNECTION_STRING}
    custom_events_enabled: true

service:
  extensions: [health_check, bearertokenauth]
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, transform/custom_events, batch]
      exporters: [azuremonitor]
```

[todo] Save it as `infra/azure/otel-collector.yaml`. Container Apps cannot bind-mount a single file, so pick one way to deliver it:

1. **Config in an env var** (simplest): store the YAML as a Container Apps secret and start the collector with `--config=env:OTELCOL_CONFIG`.
2. Custom image (`FROM otel/opentelemetry-collector-contrib:0.120.0` + `COPY`) pushed to an ACR.
3. Azure Files volume mounted at `/etc/otelcol`.

[todo] Write it as Bicep (`infra/azure/main.bicep`) instead of loose `az` commands so the environment can be recreated.

### 3.4 Endpoint and token

- The endpoint is written into every installed `settings.json`, so it must **not change**. Prefer a custom domain (e.g. `ai-hooks-telemetry.plainconcepts.com`, CNAME to the Container App, managed certificate) over the generated `*.azurecontainerapps.io` FQDN.
- Hooks append `/v1/logs`, so `otel.endpoint` is the bare origin: `https://ai-hooks-telemetry.plainconcepts.com`.
- The ingest token is stored **in clear text** on every machine (`otel.headers.Authorization`). It only grants writing telemetry, nothing else. Treat it as a spam filter, not a secret.
- Rotation: changing it needs a new package on every machine. [todo] Check whether the pinned `bearertokenauth` version accepts several tokens, so old and new work during the rollout. If not, rotate by deploying a second collector revision.
- Optional hardening: restrict ingress by IP to the corporate egress or VPN ranges. This breaks telemetry from home without VPN; the queue absorbs it, but events arrive late or get dropped at the cap.

### 3.5 Verify Azure

```powershell
curl.exe -i -X POST https://<endpoint>/v1/logs -H "Content-Type: application/json" -d "{}"   # 401 without token
powershell -NoProfile -File <install>\dispatch.ps1 -Event selftest                           # {"ok":true,...} on a configured machine
```

Then in App Insights (1 to 3 minutes later), the KQL query from `infra/local/README.md` §4.

## 4. Repo and CI

### 4.1 Production configuration

The package must ship a `config/settings.json` with:

| Key | Production value |
|---|---|
| `otel.endpoint` | Endpoint from §3.4 |
| `otel.headers.Authorization` | `Bearer <hodor-ingest-token>` |
| `identity.salt` | Real salt from Key Vault. **The repo default `CHANGE-ME-IT-SALT` must never ship**: with it, `pc.user_hash` is reversible by anyone who has the repo and a list of emails. Changing it later breaks continuity of every user hash |
| `identity.mode` | `hash` (default) or `email`; a privacy decision, see `docs/tasks.md` |
| `telemetry.projectMode` | `name` or `hash` (pending decision in `docs/tasks.md`) |
| `policy.blockSeverity` | `critical` |
| `support.channel` | Real support channel |

The pipeline writes these at build time from GitHub secrets / Key Vault; they are never committed.

### 4.2 Intune installer: `packaging/install.ps1` [todo]

Runs as **SYSTEM** (Intune Win32 app). Based on `install-local.ps1` but without the user-profile steps and without running the test suite:

1. Copy the files to `C:\ProgramData\PlainConcepts\ai-hooks\` (no `tests/`, `infra/`, `docs/`).
2. Write the production `config/settings.json` (§4.1), keeping nothing from previous installs except what IT decides.
3. Include the stamped `build-info.json`; write `HKLM\SOFTWARE\PlainConcepts\AIHooks\Version` for the detection rule.
4. `Unblock-File` everything. The Copilot hook calls `dispatch.ps1` without `-ExecutionPolicy Bypass`, so it runs under the machine policy. Under `RemoteSigned` it works once unblocked; under **`AllSigned`** (GPO/Intune) it fails, and the scripts would have to be **code-signed**. Check the actual policy on corporate machines.
5. Write the Claude Code managed settings (§5.3), if delivered from this package.
6. Uninstall script: remove the folder, the registry key and the Claude managed hooks.

`%LOCALAPPDATA%\...\logs` does not need to be created: the hooks create it on first run.

### 4.3 Package and publish: `packaging/build.ps1` + `.github/workflows/release.yml` [todo]

On every merge to `main`:

1. Checkout with `fetch-depth: 0` (needed by the version).
2. Run `tests/run.ps1` and `tests/run.sh` (same as `tests.yml`).
3. `tools/stamp-build-info.ps1` → `build-info.json` (`MAJOR.MINOR.<commits>+g<sha>`).
4. Write the production `settings.json` from secrets.
5. `New-IntuneWin32AppPackage` (module IntuneWin32App) → `.intunewin`.
6. Publish via Microsoft Graph (`Add-IntuneWin32App`), assigned to the **pilot** group, superseding the previous version.

Graph access: an Entra **app registration** with `DeviceManagementApps.ReadWrite.All` (application permission, admin consent). Authenticate from GitHub Actions with **workload identity federation (OIDC)**, so there is no certificate or secret to rotate. A certificate in Key Vault also works.

## 5. Intune

### 5.1 Win32 app "Plain Concepts AI Hooks"

- Install command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\install.ps1`, **system** context.
- Detection rule: registry `HKLM\SOFTWARE\PlainConcepts\AIHooks\Version` equals the package version (or `build-info.json` version).
- Supersedence: each new version supersedes the previous one (update, not side-by-side).
- Assignments by **rings**: pilot group (10 to 20 people) → team → BU → company. The pipeline publishes to pilot only; promotion is manual.

### 5.2 Per-user Copilot hook [todo]

`~/.copilot/hooks/company-hooks.json` (read by both VS Code and Copilot CLI) lives in **each user's profile**, which a SYSTEM install does not reliably reach. Options:

1. A second, small Win32 app (or Intune platform script) in **user** context that copies `adapters/copilot/company-hooks.json` from `C:\ProgramData\...` to the profile. Requires the main app as a dependency.
2. Let the remediation script (§5.5) create it.
3. **GitHub enterprise-managed plugins** (public preview): hooks defined in the org's `.github-private` repo, installed automatically on sign-in to Copilot in VS Code and Copilot CLI. Removes this step from Intune entirely if it matures. See `plan-company-hooks-v1.md` §7.

Recommended now: option 1, with option 2 as a safety net.

### 5.3 Claude Code managed settings [todo]

The hooks go into Claude Code **managed settings**, which users cannot disable (unlike `~/.claude/settings.json`, which `install-local.ps1` uses for testing). Content: the `hooks` object of `adapters/claude/hooks-fragment.json`.

- Delivery: either the Win32 installer writes the machine-wide `managed-settings.json`, or an Intune configuration profile sets the Claude Code policy registry key (`HKLM\SOFTWARE\Policies\ClaudeCode`). Check the current path and format in the [Claude Code settings docs](https://code.claude.com/docs/en/settings) when implementing.
- If the organization already deploys Claude Code managed settings (permissions, model, etc.), the hooks must be **merged** into that same file or policy, not overwrite it. Agree on a single owner.

### 5.4 VS Code policy [todo]

Agent hooks in VS Code are a preview feature and off by default (`chat.useHooks`). Enforce it with the VS Code **`ChatHooks`** policy via Intune Settings Catalog (VS Code ADMX imported) or a registry configuration profile. No Win32 packaging needed.

### 5.5 Remediation [todo]

Intune Remediations, daily, **user** context:

- Detection: `dispatch.ps1` exists and its hash matches the installed version; `~/.copilot/hooks/company-hooks.json` exists and points to `C:\ProgramData\...`.
- Remediation: restore the Copilot hook file. A broken main install is fixed by reinstalling the Win32 app, not by the script.

### 5.6 macOS / Linux [todo]

The bash dispatcher exists (`dispatch.sh`, path `/opt/plainconcepts/ai-hooks/`), but there is no packaging for it. For Intune-managed Macs: a `.pkg` or an Intune shell script. Out of scope for the first rollout unless decided otherwise.

## 6. Rollout order

1. Azure: App Insights + Key Vault + collector (§3). Verify with `curl` and a `selftest` from one machine installed with `install-local.ps1 -OtelEndpoint <prod> -OtelToken <token>`.
2. Decide the open privacy items (`identity.mode`, `telemetry.projectMode`, evidence in telemetry) and generate the real salt.
3. Repo: `packaging/install.ps1`, `build.ps1`, `release.yml`, `infra/azure/` (Bicep + collector config).
4. Entra: app registration for Graph publishing.
5. Intune: Win32 app + per-user hook + Claude managed settings + VS Code policy, assigned to the **pilot** group only.
6. Pilot (4 to 6 weeks): check events in App Insights, false positives, latency, `hooks-error.jsonl`. Build the KQL queries and workbook (C5).
7. Promote ring by ring. Add the remediation before the company-wide ring.

## 7. Verify on a target machine

```powershell
# Version and wiring (Claude + Copilot hooks found, paths)
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PlainConcepts\ai-hooks\tools\hodor-version.ps1
# End to end against the production collector
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PlainConcepts\ai-hooks\dispatch.ps1 -Event selftest
```

`selftest` must return `"ok":true`; `"status":401` means a wrong token, no status means the endpoint is unreachable (proxy, firewall, DNS). Then run the checks in `docs/manual-test-battery.md`.

## 8. Open points

- [ ] Code signing needed? Depends on the corporate PowerShell execution policy (§4.2).
- [ ] Corporate proxy: the hooks use `Invoke-WebRequest` (system proxy) and `curl`; confirm they reach the endpoint from the office and over VPN.
- [ ] Who owns Claude Code managed settings in the organization (§5.3).
- [ ] Multiple-token rotation in `bearertokenauth` (§3.4).
- [ ] Retention and daily cap of the workspace (§3.1).
- [ ] GitHub enterprise-managed plugins as a replacement for the per-user Copilot step (§5.2).
