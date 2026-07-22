# Hodor: manual test battery (Claude Code)

A set of prompts to paste **into the Claude Code chat**, one at a time, to exercise the hooks end to end.

> **All tokens below are fake.** They are test values chosen only to match the detection patterns. None are real secrets.

## Before you start

- Install (or reinstall) the hooks and reload Claude Code so they load:
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
  ```
- In Claude Code, the `UserPromptSubmit` event **blocks** on a critical finding (unlike VS Code / Copilot chat surfaces, where the same event is advisory only).
- Everything is recorded locally under `%LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\` (`security.jsonl`, `telemetry-queue.jsonl`). View it in the dashboard (see the end).

## 1. Must BLOCK (critical: prompt is stopped, never reaches the model)

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
| 1 (critical) | Prompt **blocked**, message `[...AI policy BLOCK]`, the model does not answer |
| 2 and 3 (high / medium) | Warning `[...AI policy WARNING]`, the model answers |
| 4 (clean) | No warning, normal answer |
| 5 (skills) | No warning; a `skill_usage` event is recorded |

## Inspect the results

Open the offline dashboard and drag your log file onto it:

```
start "" "%LOCALAPPDATA%\PlainConcepts\ai-hooks\tools\dashboard.html"
```

Drag `logs\telemetry-queue.jsonl` (and `logs\security.jsonl` for findings with severity and block/warn). You will see policy findings grouped by severity and skills/agents ranked by usage.

If a critical prompt does **not** block in your Claude Code surface, note what you see: it would mean that surface treats `UserPromptSubmit` as advisory (like VS Code / Forge), which is a known platform limitation.
