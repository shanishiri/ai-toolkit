# generate-api-manual-test-plan

A Claude Code skill that produces a self-contained, agent-runnable end-to-end test plan for an API feature or bug fix, with per-scenario [Dash0](https://www.dash0.com) trace + log deep-links scoped to each run.

**Audience:** Dash0 users who instrument their local service with OpenTelemetry and want one-command end-to-end validation of an API change against a running local instance.

**Not for:** UI flows (use a Playwright plan), library/SDK changes with no API surface, or services without a local-runnable mode.

## What you get

Invoking the skill produces a single markdown file at a path you choose (default `docs/test-plans/YYYY-MM-DD-<feature>-manual-test-plan.md`) containing:

- **§0 Pre-flight** — verifies `.env.local` is present, the service is reachable, and (optionally) starts a catch-all HTTP listener for callback URLs.
- **§1 Helpers** — bash functions for building requests, capturing responses, reading side-effect state, and recording per-scenario results. Includes a Dash0 URL generator (`dash0_link`) wired to your org + dataset + service.
- **§2 Scenarios** — one fail-fast bash block per scenario, asserting on response shape AND persisted state via `jq -e`.
- **§3 Results table (printed on exit)** — six-column table: `# | Scenario | Status | HTTP | Outcome | Traces | Logs`. The Traces/Logs columns are deep-links into the Dash0 UI pre-filtered to the exact fixture ID that ran in that scenario.

Run the saved plan via `bash <plan-file>` from inside your service directory. PASS/FAIL is the exit code; the rendered table summarises every run.

## Prerequisites

The skill **verifies these itself** during preflight and stops with a clear message if anything is missing. Don't worry about getting them perfect first — re-invoke after fixing whatever it flags.

1. **A local service running** with OpenTelemetry instrumented and exporting to Dash0. The service must be reachable on a known local port at the time the plan is run (not at the time the plan is generated — they can be separate moments).
2. **`<service-dir>/.env.local` exists and is gitignored**, exporting the env vars listed below. The skill reads this file to derive the Dash0 ingress host, app host, dataset, service name, org slug, and any local API auth tokens.
3. **`jq`, `curl`, `uuidgen`, `python3`** on the PATH. (No `docker` requirement at run time; only if your service runs in Docker locally.)
4. **A Dash0 auth token** scoped to your dev/test org (Dash0 dev UI → Settings → Auth Tokens). Used by both OTel ingestion and the Dash0 UI deep-links.

## Installation

```bash
# 1. Clone or copy this directory to your Claude skills folder
mkdir -p ~/.claude/skills
cp -r generate-api-manual-test-plan ~/.claude/skills/

# 2. Verify Claude can see it (lists in the available skills section)
#    No registration step needed — Claude Code auto-discovers skills here.

# 3. Set up your .env.local in your service directory (see next section)
cp ~/.claude/skills/generate-api-manual-test-plan/.env.local.example \
   <your-service-dir>/.env.local
# Then edit the file: paste your Dash0 auth token, org slug, app host,
# and any local API credentials your service needs.

# 4. Source the env and start your service in one shell
cd <your-service-dir>
source .env.local && <your start command, e.g. make run>

# 5. In another shell (or via Claude Code), invoke the skill
#    Claude will read .env.local, verify the service is reachable, and
#    interview you only for what it can't infer from your codebase.
```

## .env.local setup

See [`.env.local.example`](.env.local.example) for the full template. Required variables:

| Variable | Purpose | Where to get it |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Master gRPC OTLP endpoint for traces + metrics | Dash0 docs → "Configure OpenTelemetry" |
| `OTEL_EXPORTER_OTLP_HEADERS` | Includes `Authorization: Bearer <token>` and `Dash0-Dataset=<name>` | Token from Dash0 UI → Settings → Auth Tokens |
| `OTEL_SERVICE_NAME` | Unique name so Dash0 deep-links scope to *your* local instance | Pick something like `<service>-<user>-local` |
| `DASH0_ORG` | Dash0 org slug (the value after `?org=` in any Dash0 UI URL you've opened) | Look at any working `app.dash0.com/...` URL |
| `DASH0_APP_HOST` | The Dash0 UI host that pairs with your ingress region | `app.dash0.com` or `app.dash0-dev.com` |

Optional but recommended:

| Variable | Purpose |
|---|---|
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` / `OTEL_EXPORTER_OTLP_LOGS_HEADERS` | Required if your service uses an HTTP-only logs exporter (e.g. `agoda-com/opentelemetry-logs-go`) that does not inherit the gRPC `OTEL_EXPORTER_OTLP_*` master vars. |
| `API_TOKEN`, `API_BEARER`, `LOCAL_API_BEARER`, or any project-prefixed alias | Bearer token the local service accepts as admin auth. The skill picks the first defined name and references it as `$VAR` in scenarios — no value is ever pasted into the markdown. |
| `TENANT_ID`, `ORG_ID`, `ORG_TECHNICAL_ID` | Tenant/org context for routes that require one in the URL path or request body. |

Two identifiers that are **easy to confuse but must stay separate**:

- `DASH0_ORG` (Dash0 UI org slug) — goes into the generated URL's `?org=` param. The Dash0 UI shows "Organization not found" if this is wrong.
- Test-fixture organization ID (e.g. on a CloudFormation template parameter or in a multi-tenant request body) — owned by the scenario, lives in §2, can be any throwaway string. **Never use one for the other.**

## What the skill does NOT do

- Create or edit `.env.local`. That's your setup.
- Start, restart, or modify the running service. Verification only.
- Inline any secret into the generated markdown. Tokens stay in env vars, referenced as `$VARNAME`.
- Mint Dash0 auth tokens or change org/dataset config.

This keeps the skill's permission surface minimal — it only needs `Read`/`Grep`/`Glob`/`Write` plus `Bash` restricted to the bundled `scripts/encode-dash0-link.py` and `curl http://localhost*`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Organization not found` opening a generated link | `DASH0_ORG` is unset or wrong | Look at any working Dash0 UI URL you've opened; the value after `?org=` is your slug. Set `export DASH0_ORG=<slug>` in `.env.local`. |
| Results table doesn't render at end of run | mktemp template broken — should never happen with current boilerplate, but if it does, check that `RESULTS_TSV=$(mktemp "${TMPDIR:-/tmp}/test-results.XXXXXX")` is in §1 (X's at end of basename). | Re-generate the plan; the skill's boilerplate already uses the portable form. |
| Plan exits with `✗ <VAR> is still a placeholder` | The plan-generator missed substituting `<your-org-slug>` / `<your-dash0-app-host>` / `<attribute-key>` before saving. | Either re-generate, or edit the saved plan to fill them in. The runtime guard exists so you don't silently get 404 links. |
| Plan asks for auth even though `.env.local` has the token | The token is exported under a name the skill doesn't recognise. | Either rename to `API_TOKEN` / `API_BEARER`, or add an alias: `export API_TOKEN=$YOUR_TOKEN_VAR`. |
| `curl: (22)` on a 401 probe | Old skill version used `curl -fsS` for liveness probes | Re-generate; current boilerplate uses `curl -s -w '%{http_code}'` and only treats `000` (connection refused) as down. |

## Layout

```
generate-api-manual-test-plan/
├── README.md                        (this file)
├── SKILL.md                         (the skill body — Claude reads this)
├── .env.local.example               (template you copy into your service dir)
├── boilerplate/                     (chunks the skill inlines into each plan)
│   ├── preflight-service-check.sh   (§0.1 of the generated plan)
│   ├── catchall.sh                  (§0.2 — only when callback URLs exist)
│   ├── results-table.sh             (§1 — record_result, dash0_link, table+trap)
│   └── scenario-template.sh         (§2 — per-scenario block)
└── scripts/
    └── encode-dash0-link.py         (Dash0 UI URL state encoder)
```

## License

Pick the license that fits your distribution. The skill has no third-party dependencies and the Dash0 UI URL state encoding is a stable public format.
