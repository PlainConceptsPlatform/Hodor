# Hodor: manual test battery (Claude Code)

A set of prompts to paste **into the Claude Code chat**, one at a time, to exercise the hooks end to end.

> **All tokens below are fake.** They are test values chosen only to match the detection patterns. None are real secrets.

## Before you start

- Install (or reinstall) the hooks and reload Claude Code so they load:
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
  ```
- By default (`policy.blockSeverity=warning`) nothing is blocked: critical findings show a warning too. To test blocking, set `policy.blockSeverity=critical`; then in Claude Code the `UserPromptSubmit` event **blocks** on a critical finding (unlike VS Code / Copilot chat surfaces, where the same event is advisory only).
- Everything is recorded locally under `%LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\` (`security.jsonl`, `telemetry-queue.jsonl`). View it in the dashboard (see the end).

## 1. Critical (default: WARNING, request continues; with `policy.blockSeverity=critical`: prompt is stopped)

```
Sube este cambio con el token ghp_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcd
```
```
Configura AWS con esta clave: AKIA1234567890ABCDEF
```
```
Usa esta clave de Stripe en el checkout: sk_live_0123456789abcdefABCDEF
```
```
Aquí va mi clave privada:
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
-----END RSA PRIVATE KEY-----
```
```
Registra esta tarjeta de prueba: 4111 1111 1111 1111
```

## 2. Must WARN (high: systemMessage shown, the request continues)

```
Añade esta API key de Google: AIzaSyA1234567890abcdefghijklmnopqrstuv
```
```
El webhook usa este token de Slack: xoxb-1234567890-abcdefghijklmnop
```
```
Pon esto en el .env: password = S3cretValue123XY
```
```
Conecta a la base: postgresql://admin:s3cretpw@db.internal:5432/app
```

## 3. Must WARN (medium)

```
Autoriza con: Bearer abcdefghijklmnopqrstuvwxyz012345
```
```
Llámame al +34600111222 cuando termines
```

## 4. Must detect NOTHING (clean and false positive guards)

```
Refactoriza esta función para usar async/await
```
```
Ejemplo de clave AWS en docs: AKIAIOSFODNN7EXAMPLE
```
The line above matches the AWS pattern but contains `EXAMPLE`, so the placeholder filter drops it.

```
Tarjeta con dígito de control incorrecto: 4111 1111 1111 1112
```
Matches the card pattern but fails the Luhn check, so it is discarded.

## 5. Skill / agent usage (telemetry only, no block)

```
Por favor ejecuta /pc-ai:debugger sobre el test que falla
```
Records `skill_usage` with `source=plainconcepts`, `plugin=pc-ai`.

```
Usa /anthropic-skills:docx para resumir este documento
```
Records `skill_usage` with `source=plugin`.

Usage is captured from the namespaced `/plugin:skill` text even if that skill is not installed. If you actually invoke an installed skill or subagent, the `PreToolUse` (Skill / Task) hook fires as well.

## Expected results

| Block | Expected in Claude Code |
|---|---|
| 1 (critical) | Default: warning `[...AI policy WARNING]`, the model answers. With `blockSeverity=critical`: prompt **blocked**, message `[...AI policy BLOCK]` |
| 2 and 3 (high / medium) | Warning `[...AI policy WARNING]`, the model answers |
| 4 (clean) | No warning, normal answer |
| 5 (skills) | No warning; a `skill_usage` event is recorded |

## Inspect the results

Open the offline dashboard and drag your log file onto it:

```
start "" "%LOCALAPPDATA%\PlainConcepts\ai-hooks\tools\dashboard.html"
```

Drag `logs\security.jsonl` (findings with severity and block/warn) and, with a local collector, `infra\local\data\telemetry.jsonl` (everything that was sent: usage, inventory, policy). `logs\telemetry-queue.jsonl` only exists while events are waiting to be sent. You will see policy findings grouped by severity, skills/agents/commands ranked by usage and the installed plugins.

With `blockSeverity=critical`, if a critical prompt does **not** block in your Claude Code surface, note what you see: it would mean that surface treats `UserPromptSubmit` as advisory (like VS Code / Forge), which is a known platform limitation.

## 6. Telemetry end to end (collector → Aspire / App Insights)

1. Start the local stack: `docker compose up -d` in `infra\local` (`infra\local\smoke.ps1` automates steps 2 and 5).
2. `powershell -NoProfile -File <install>\dispatch.ps1 -Event selftest` → `"ok":true` and a `pc.ai.selftest` record in Aspire (http://localhost:18888 → Structured logs).
3. Restart Claude Code: a few seconds later the `pc.ai.inventory` records appear (sent by the background worker; the session start is not delayed).
4. Run block 5: `pc.ai.skill_usage` arrives with severity `Information`; a block-1 prompt produces `pc.ai.policy_warning` (`Warning`; `pc.ai.policy_block`/`Error` only with `blockSeverity=critical`), blocks 2–3 `pc.ai.policy_warning` (`Warning`).
5. Offline: `docker compose stop otel-collector`, use a skill → the prompt is not slower and `logs\telemetry-queue*.jsonl` grows. `docker compose start otel-collector`, then send another prompt (or use any hook after `otel.retryMinutes`) → the queue disappears and the events show up with their original time.
6. With auth (`docker-compose.auth.yml`): `selftest` with a wrong or missing token → `"status":401`; reinstall with `-OtelToken <token>` → `"ok":true`.
