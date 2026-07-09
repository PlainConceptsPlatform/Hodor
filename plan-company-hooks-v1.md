# Company AI Hooks 1.0 — Plan simplificado

**Objetivo:** hooks corporativos para los agentes de coding IA que (1) **avisen** al usuario cuando un prompt incumple la política de la empresa, (2) registren esos avisos, los errores del propio hook y el **uso de skills/agents** en Azure Application Insights vía OpenTelemetry. Nada más en v1.

**Estado:** v2 simplificado · Junio 2026 · Owner: Javier

---

## 1. Alcance y decisiones

| Decisión | Valor |
|---|---|
| IDEs soportados | **VS Code (Copilot Chat)**, **Copilot CLI**, Claude Code. Diseñado Copilot-first (90% de la plantilla); Claude Code es extra para no anclarse a una plataforma |
| Política v1 | **Warning, no bloqueo**: el usuario ve un aviso de que su prompt no cumple la política, pero la petición continúa |
| Fuera de v1 | Exfiltración (PreToolUse sobre bash/web_fetch), DNI español, detección de nombres propios (NER), bloqueo, telemetría de uso general |
| Log local | **Circular**: tamaño máximo con rotación, sin crecimiento indefinido |
| Telemetría | OTel → App Insights. Solo 3 eventos: prompts con warning, issues del hook, uso de skills/agents |
| Distribución | Repo GitHub **privado** (separado del marketplace de skills) → CI genera `.intunewin` en cada cambio → Intune |

---

## 2. Arquitectura de hooks

### 2.1 Una carpeta de scripts, tres consumidores

Los scripts viven en una carpeta machine-wide (`C:\ProgramData\PlainConcepts\ai-hooks\`; macOS/Linux: `/opt/plainconcepts/ai-hooks/`) y los tres agentes los invocan mediante ficheros de configuración finos:

- **VS Code y Copilot CLI comparten ubicación**: ambos leen `~/.copilot/hooks/*.json` (VS Code además lee `.github/hooks` del workspace y formato Claude). Un solo fichero `company-hooks.json` cubre las dos superficies.
- **Claude Code**: sección `hooks` en managed settings (registro `HKLM\SOFTWARE\Policies\ClaudeCode` / `managed-settings.json`), no desactivable por el usuario.
- En VS Code, activar la policy ADMX **`ChatHooks`** vía Intune para garantizar que los hooks corren.

```
ai-hooks/
├── VERSION
├── dispatch.sh / dispatch.ps1     # entrada única: dispatch <evento>; normaliza payloads
├── lib/
│   ├── common.sh                  # parseo stdin, contexto, log circular
│   ├── logrotate.sh               # rotación: security.jsonl, máx 5 MB × 3 ficheros
│   └── otel.sh                    # envío OTLP (curl) con cola local y flush en sessionEnd
├── layers/
│   ├── policy/
│   │   ├── scan-prompt.sh         # análisis del prompt contra patterns.d → warning
│   │   └── patterns.d/            # un fichero por familia de reglas
│   └── usage/
│       └── usage.sh               # detección de invocaciones de skills/agents
└── config/
    ├── settings.json              # endpoint OTel, log, umbral de bloqueo, prefijo de plugin de la org
    └── allowlist.txt              # falsos positivos aprobados (PR al repo)
```

> **Nota v1.1:** la política pasó de *warning* a **bloqueo en severidad crítica** (`policy.blockSeverity`, por defecto `critical`; `high`/`medium` siguen como warning). La telemetría de skills/agents cubre **todo** el uso y clasifica por el **namespace del plugin** (`plugin:skill`): prefijo `skills.orgPluginPrefix` (`pc-`) → Plain Concepts. Ya no se usa `marketplace-index.json`.

### 2.2 Eventos y mecánica de warning por plataforma

| Plataforma | Evento prompt | Cómo se muestra el warning (sin bloquear) |
|---|---|---|
| VS Code | `UserPromptSubmit` | stdout JSON `{"systemMessage": "⚠️ …"}` (mecanismo oficial de warning) o exit code ≠ 0 y ≠ 2 (= "non-blocking warning") |
| Copilot CLI | `userPromptSubmitted` | ⚠️ Limitación: el CLI ignora el output de este evento. El warning queda en log local + telemetría; mensaje best-effort por stdout |
| Claude Code | `UserPromptSubmit` | exit 1 (error no bloqueante): stderr se muestra al usuario; exit 0 + stdout añade el aviso como contexto |

Notas técnicas: VS Code usa PascalCase y **ignora los matchers** (el script filtra internamente por `tool_name`); el CLI usa camelCase con claves `bash`/`powershell` por entrada; `dispatch` absorbe estas diferencias. El uso de skills se captura en `UserPromptSubmit` (invocaciones `/skill`) y, en Claude Code, también con `PreToolUse` matcher `Skill`.

### 2.3 Texto del warning

> ⚠️ Este prompt no cumple la política de IA de Plain Concepts: posible **GitHub token** detectado (`ghp_…XXXX`). La petición continúa, pero revisa qué estás compartiendo con el modelo. Detalle: `%LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\security.jsonl` · Dudas/falsos positivos: #ai-hooks en Teams.

### 2.4 Log local circular

- Ruta: `%LOCALAPPDATA%\PlainConcepts\ai-hooks\logs\` (macOS/Linux: `~/.local/state/plainconcepts/ai-hooks/`).
- JSONL, una línea por evento, evidencia siempre redactada (4 primeros + 4 últimos caracteres), nunca el prompt completo.
- **Rotación por tamaño**: al superar 5 MB → `security.jsonl` → `security.1.jsonl` → `security.2.jsonl` → se elimina. Máximo ~15 MB por máquina. Mismo esquema para `hooks-error.log`.

---

## 3. Reglas de la política (v1)

Solo regex en shell (<50 ms), heredadas de `secrets-scanner`/`governance-audit` de github/awesome-copilot:

| Familia | Ejemplos | Acción |
|---|---|---|
| Claves cloud | AWS `AKIA[0-9A-Z]{16}`, GCP `AIza…`, Azure client secrets | Warning |
| Tokens de plataforma | GitHub `ghp_/gho_/ghs_/github_pat_`, Slack `xox…`, npm, Stripe `sk_live_`, SendGrid, Twilio | Warning |
| Claves privadas | `-----BEGIN … PRIVATE KEY-----` | Warning |
| Credenciales genéricas | `password|secret|token|api_key [:=] valor{8,}`, Bearer, JWT, connection strings con credenciales | Warning |
| Tarjetas de crédito | 13–19 dígitos + validación Luhn | Warning |
| Datos bancarios / contacto | IBAN `ES[0-9]{22}`, teléfonos `(\+34)?[679][0-9]{8}` | Warning |

Anti-falsos-positivos: placeholders (`example`, `your_`, `changeme`, `dummy`…), lockfiles, y `allowlist.txt` gestionada por PR al repo privado.

**Eliminado de v1** (candidato a futuras versiones): reglas de exfiltración en `PreToolUse`, DNI español, NER de nombres propios, modo bloqueo.

---

## 4. Telemetría: OTel → Application Insights

### 4.1 Solo tres eventos

| Evento | Atributos |
|---|---|
| `pc.ai.policy_warning` | regla, severidad, agente (vscode/copilot-cli/claude-code), evidencia redactada, user_hash, ts |
| `pc.ai.hook_issue` | tipo de error (timeout, parseo, sin red…), agente, versión de hooks, ts |
| `pc.ai.skill_usage` | skill, plugin, `pc.source` (`plainconcepts` / `plugin` / `personal`), `pc.kind` (`skill`/`agent`), agente, user_hash, ts |

`user_hash` = SHA-256 de email + sal corporativa (custodiada por IT). Nunca se envía contenido de prompts. Envío OTLP/HTTP con `curl` en background; si no hay red, cola en disco y flush en `sessionEnd`.

### 4.2 Crear el App Insights en Azure (pasos)

Workspace-based (el modo classic está retirado):

```bash
# 1. Resource group
az group create -n rg-ai-hooks -l westeurope

# 2. Log Analytics workspace (almacenamiento subyacente)
az monitor log-analytics workspace create -g rg-ai-hooks -n law-ai-hooks -l westeurope

# 3. Application Insights vinculado al workspace
az extension add -n application-insights
az monitor app-insights component create --app appi-ai-hooks -g rg-ai-hooks \
  -l westeurope --workspace law-ai-hooks

# 4. Connection string (la usará el collector / config de los hooks)
az monitor app-insights component show --app appi-ai-hooks -g rg-ai-hooks \
  --query connectionString -o tsv
```

**Ingesta OTLP**: Azure Monitor anunció en Build 2026 la ingesta OTLP nativa como GA (incluye explícitamente señales de coding agents — Copilot y Claude Code — con vistas curadas en App Insights). Dos opciones:

1. **OTLP directo** a los endpoints de Azure Monitor con auth Entra ID (verificar estado GA en Learn al implementar; algunas páginas siguen marcadas preview).
2. **OTel Collector ligero** (Container App) con `azuremonitorexporter` + connection string — vía clásica, funciona hoy seguro y da un punto de filtrado/anonimización. **Recomendada para v1.**

Dashboard: workbook de App Insights con warnings por regla (para calibrar falsos positivos), issues por versión de hooks, y ranking de skills por origen.

### 4.3 Por qué solo hooks (y no las APIs de métricas) en v1

La Copilot usage metrics API y las Analytics APIs de Anthropic quedan fuera de v1 deliberadamente. Son el camino natural para ampliar métricas en el futuro sin tocar las máquinas (son server-side), pero los tres datos que quieres ahora — warnings, issues, skills — **solo los dan los hooks**.

---

## 5. Distribución: repo privado → CI → Intune

### 5.1 Repo `company-ai-hooks` (privado, separado del marketplace)

```
company-ai-hooks/
├── src/                  # scripts (estructura §2.1)
├── adapters/             # company-hooks.json (Copilot), fragmento managed-settings (Claude)
├── tests/                # tests de contrato: payloads reales de los 3 agentes contra dispatch
├── packaging/
│   ├── install.ps1       # instala scripts + configs; escribe HKLM\...\AIHooks\Version
│   └── build.ps1         # IntuneWin32App: New-IntuneWin32AppPackage → .intunewin
└── .github/workflows/release.yml
```

### 5.2 Pipeline (en cada merge a `main`)

1. Tests de contrato: la suite sin dependencias `tests/run.ps1` + `tests/run.sh` (fixtures compartidos en `tests/cases/`) valida que los payloads de los 3 agentes producen la decisión esperada en ambos dispatchers. Se ejecuta también en `.github/workflows/tests.yml` en cada push/PR.
2. **Versión derivada de git** (checkout con `fetch-depth: 0`): `tools/stamp-build-info.ps1` calcula `MAJOR.MINOR.<commit-count>+g<sha>` (base en `VERSION`) y escribe `build-info.json` en el paquete. El patch sube solo en cada commit; no hay bump manual. Tag opcional con esa versión.
3. `build.ps1` genera el `.intunewin` (módulo **IntuneWin32App** de MSEndpointMgr; runner Windows) incluyendo `build-info.json`.
4. Publicación automática en Intune vía Graph (`Add-IntuneWin32App`, service principal con certificado en Key Vault) al ring de pilotos; promoción manual al ring general.
5. Detection rule: `build-info.json` (o `HKLM\SOFTWARE\PlainConcepts\AIHooks\Version`) = versión completa. Supersedence entre versiones.
6. **Remediation** diaria (contexto usuario): verifica hash de `dispatch` y existencia de `~/.copilot/hooks/company-hooks.json`; repara drift.

Este patrón ("configuration as code" para Intune, pipeline que empaqueta y publica) es práctica documentada y común a nivel enterprise — referencias: IntuneAppFactory de MSEndpointMgr (exactamente este flujo), blog oficial de Intune Customer Success.

---

## 6. Fases

### Fase 1 — Piloto (4–6 semanas)

- Crear App Insights (§4.2) + collector.
- Repo + pipeline + primer `.intunewin`.
- Despliegue a 10–20 voluntarios (grupo Intune): hooks en modo warning en VS Code, Copilot CLI y Claude Code.
- Canal #ai-hooks para falsos positivos; revisión semanal de reglas con el dashboard; allowlist por PR.
- Comunicación previa a los pilotos: qué se registra (warnings redactados, issues, skills) y qué no (contenido de prompts, código).
- **Salida:** falsos positivos < 5% de warnings, latencia < 100 ms P95, 0 incidencias de pérdida de trabajo, warnings visibles y comprensibles.

### Fase 2 — Despliegue a compañía (rings)

- Promoción del paquete por rings de Intune (equipo → BU → compañía) con el mismo pipeline.
- Dashboard compartido con los equipos; métricas de skills alimentando (manualmente al principio) la sección Metrics del marketplace.
- Revisión trimestral de reglas. Cualquier endurecimiento (bloqueo, exfiltración, PII avanzada) será una decisión separada con sus propios datos, fuera de este plan.

---

## 7. Validación del approach y puntos de mejora

He contrastado el diseño con referencias actuales (junio 2026). Veredicto por pieza:

**✅ Confirmado como best practice:**

- **Warn primero, bloquear después**: es exactamente el rollout que Microsoft documenta para Purview DLP (simulation mode → policy tips → enforcement, revisando datos entre fases).
- **Repo de configuración → CI → `.intunewin`**: patrón establecido ("configuration as code" de Intune, IntuneAppFactory/IntuneWin32App de MSEndpointMgr lo implementan tal cual).
- **Hooks para gobernanza de coding agents**: respaldado por la guía "Governing agents" del GitHub Well-Architected Framework y productos como Endor Labs Agent Governance.
- **OTel + App Insights para coding agents**: Microsoft lo presentó en Build 2026 como escenario soportado de fábrica (vistas curadas de Copilot/Claude Code en App Insights).

**⚠️ Puntos de mejora que propongo:**

1. **GitHub enterprise-managed plugins (mayo–junio 2026, public preview) puede sustituir a Intune para distribuir los hooks.** Un fichero en el repo `.github-private` de la org (`.github/copilot/settings.json`) define plugins con hooks que se instalan **automáticamente al autenticarse** cualquier usuario con seat de Copilot Business/Enterprise — en VS Code y Copilot CLI, en cualquier máquina, sin agente de despliegue y con actualización automática (tu requisito de agilidad, resuelto de forma nativa). El repo privado de hooks seguiría existiendo; el CI haría PR/sync a `.github-private` en vez de generar `.intunewin`. **Recomendación:** pilotar ambas vías en Fase 1; si managed plugins madura (hoy es preview), Intune queda solo para lo que GitHub no cubre: Claude Code managed settings, policies ADMX de VS Code (`ChatHooks`) y remediación anti-drift.
2. **Para las policies de VS Code no hace falta Win32**: se despliegan como registry/ADMX vía Intune (Settings Catalog), mucho más ligero que empaquetar.
3. **Los hooks de VS Code están en preview**: el formato puede cambiar con cada release. Mitigación: tests de contrato en CI con payloads versionados y ring de pilotos que recibe actualizaciones de VS Code antes que el resto.
4. **Limitación asumida en Copilot CLI**: hoy ignora el output de `userPromptSubmitted`, así que el warning visible en chat solo está garantizado en VS Code y Claude Code; en CLI queda en log + telemetría. Si esto resulta insuficiente en el piloto, la alternativa es bloquear con mensaje (exit code) solo en CLI — decisión para Fase 2.

---

## 8. Riesgos

| Riesgo | Mitigación |
|---|---|
| Falsos positivos generan ruido y los usuarios ignoran los warnings | Calibración semanal en piloto; allowlist por PR; umbral de salida <5% |
| Cambios de formato de hooks (VS Code preview) | dispatch aísla la normalización; tests de contrato; pin de versión en ring piloto |
| Latencia perceptible | regex puro en shell; telemetría en background; presupuesto 100 ms P95 |
| Log local crece | rotación circular 5 MB × 3 (§2.4) |
| Telemetría sin red | cola en disco + flush en sessionEnd; pérdida aceptable en v1 |

---

## 9. Referencias

- Hooks de ejemplo: [governance-audit](https://github.com/github/awesome-copilot/tree/main/hooks/governance-audit) · [secrets-scanner](https://github.com/github/awesome-copilot/tree/main/hooks/secrets-scanner)
- Hooks por plataforma: [VS Code agent hooks](https://code.visualstudio.com/docs/agent-customization/hooks) · [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-configuration) · [Copilot CLI hooks](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks) · [Claude Code hooks](https://code.claude.com/docs/en/hooks) · [Claude Code managed settings](https://code.claude.com/docs/en/settings)
- Enterprise management: [Enterprise-managed plugins (docs)](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/configure-enterprise-plugin-standards) · [Changelog CLI](https://github.blog/changelog/2026-05-06-enterprise-managed-plugins-in-github-copilot-cli-are-now-in-public-preview/) · [Changelog VS Code](https://github.blog/changelog/2026-06-05-enterprise-managed-plugins-in-vs-code-in-public-preview/) · [VS Code enterprise policies](https://code.visualstudio.com/docs/enterprise/policies) · [Governing agents (GitHub Well-Architected)](https://wellarchitected.github.com/library/governance/recommendations/governing-agents/)
- Azure: [Create workspace-based App Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource) · [az monitor app-insights](https://learn.microsoft.com/en-us/cli/azure/monitor/app-insights/component) · [OTLP ingestion](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/opentelemetry-summary) · [Build 2026 Observability](https://techcommunity.microsoft.com/blog/azureobservabilityblog/what%E2%80%99s-new-in-observability-at-build-2026/4524927) · [Monitoring agents en VS Code](https://code.visualstudio.com/docs/agents/guides/monitoring-agents)
- Intune CI/CD: [IntuneWin32App](https://github.com/MSEndpointMgr/IntuneWin32App) · [IntuneAppFactory](https://github.com/MSEndpointMgr/IntuneAppFactory) · [Configuration as Code for Intune](https://techcommunity.microsoft.com/blog/intunecustomersuccess/configuration-as-code-for-microsoft-intune/3701792)
- DLP warn-first: [Purview DLP deploy](https://learn.microsoft.com/en-us/purview/dlp-create-deploy-policy)
