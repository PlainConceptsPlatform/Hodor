# Local telemetry stack

Runs the OTel Collector on your machine so the **current** hooks can be tested end to end, without cloud infra. Production (Azure + Intune): see [`docs/deployment.md`](../../docs/deployment.md).

```
hook (dispatch.ps1/.sh) --OTLP/HTTP JSON--> otel-collector :4318 --> debug (docker logs)
                                                                 --> file  (data/telemetry.jsonl)
                                                                 --> Aspire Dashboard (http://localhost:18888)
                                                                 --> App Insights (optional overlay)
```

Application Insights itself cannot run locally: the optional overlay exports to a **real dev App Insights resource** in Azure, using its connection string.

## 1. Start the stack

Requires Docker Desktop running.

```powershell
cd infra\local
docker compose up -d
docker compose ps                         # otel-collector + aspire-dashboard up
curl.exe http://localhost:13133           # collector health: {"status":"Server available",...}
```

Ports are bound to `127.0.0.1` only. The current hooks send without auth (see `docs/tasks.md`, B5).

## 2. Smoke test (no IDE, isolated settings)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\local\smoke.ps1
```

Sends a skill, an agent (`Task`), a prompt with `/plugin:skill` + a medium policy finding, and an offline-queued event flushed on `SessionEnd`. It then checks they reach `data/telemetry.jsonl`. It does not touch your installed config.

## 3. Point your installed hooks at it

In the installed `config\settings.json` (e.g. `%LOCALAPPDATA%\PlainConcepts\ai-hooks\config\settings.json`):

```json
"otel": { "enabled": true, "endpoint": "http://localhost:4318", "queueMaxSizeMB": 2 }
```

Restart Claude Code / reload VS Code, use a skill or agent, then look at:

- **Aspire Dashboard**: http://localhost:18888 → *Structured logs* (resource `pc-ai-hooks`). Filter by `pc.skill`, `pc.kind`…
- **Console**: `docker compose logs -f otel-collector`
- **File**: `infra\local\data\telemetry.jsonl`

## 4. Optional: also export to a dev App Insights

```powershell
# One-time: create a dev App Insights (or reuse one) and get its connection string
az group create -n rg-ai-hooks-dev -l westeurope
az monitor log-analytics workspace create -g rg-ai-hooks-dev -n law-ai-hooks-dev -l westeurope
az monitor app-insights component create --app appi-ai-hooks-dev -g rg-ai-hooks-dev -l westeurope --workspace law-ai-hooks-dev
az monitor app-insights component show --app appi-ai-hooks-dev -g rg-ai-hooks-dev --query connectionString -o tsv

Copy-Item .env.example .env   # paste the connection string into .env
docker compose -f docker-compose.yml -f docker-compose.appinsights.yml up -d
```

Usually within 1-3 minutes. Attributes are in `customDimensions` in both tables:

- **`customEvents`**: `pc.ai.skill_usage`, `pc.ai.inventory`, `pc.ai.policy_warning`, `pc.ai.policy_block` (event name in `name`). The overlay's `transform/custom_events` processor tags them for the exporter and copies `service.version`, `os.type` and `host.name` into `customDimensions` (the custom-event path drops resource attributes and severity).
- **`traces`**: `pc.ai.hook_issue`, `pc.ai.selftest` (event name in `message`, with severity and `cloud_RoleName`).

```kusto
customEvents
| where timestamp > ago(1h)
| where name startswith "pc.ai."
| extend skill = tostring(customDimensions["pc.skill"]), plugin = tostring(customDimensions["pc.plugin"]),
         kind = tostring(customDimensions["pc.kind"]), source = tostring(customDimensions["pc.source"]),
         agent = tostring(customDimensions["pc.agent"]), user = tostring(customDimensions["pc.user_hash"]),
         version = tostring(customDimensions["service.version"])
| project timestamp, name, kind, plugin, skill, source, agent, user, version
| order by timestamp desc
```

```kusto
traces
| where timestamp > ago(1h)
| where message in ("pc.ai.hook_issue", "pc.ai.selftest")
| project timestamp, message, severityLevel, customDimensions
| order by timestamp desc
```

## Stop / clean

```powershell
docker compose down            # keeps data\telemetry.jsonl
Remove-Item data\telemetry.jsonl*
```
