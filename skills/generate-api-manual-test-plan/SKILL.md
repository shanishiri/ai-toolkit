---
name: generate-api-manual-test-plan
description: Produce a self-contained, agent-runnable manual-test plan for an API feature or bug fix after unit + integration tests pass. Generates a markdown document with bash helpers, per-scenario assertions, and Dash0 trace/log query links scoped to the local service under test. Use after backend changes are implemented and you want end-to-end validation against a running instance. API-only — does not cover UI or pure library work.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
  - Bash(curl http://localhost*)
  - Bash(curl http://127.0.0.1*)
  - Bash(python3 ~/.claude/skills/generate-api-manual-test-plan/scripts/encode-dash0-link.py:*)
---

# generate-api-manual-test-plan

A specialised plan-writing skill that produces a manual end-to-end test plan another agent (or a human) can execute step-by-step against a running local service. The plan asserts on response shape AND on persisted state, and ends with a Dash0 traces + logs UI link scoped to the run.

## Skill layout

This file is the entry point. Heavy bash/Python is extracted into siblings so the entry point stays short. When generating a plan, `Read` each referenced file and inline its contents verbatim into the named section of the output markdown (logic stays identical to past working runs).

| File | Inlined into | What it provides |
|---|---|---|
| `boilerplate/preflight-service-check.sh` | §0.1 of the plan | `.env.local` presence + service-reachability probe (`curl -s -w '%{http_code}'`, treats `000` as down) |
| `boilerplate/catchall.sh` | §0.2 of the plan | `/tmp/catchall.py` + launch + readiness wait; only when the API has customer-supplied callback URLs |
| `boilerplate/results-table.sh` | §1 of the plan | `RESULTS_TSV`, placeholder-guard, `record_result`, `dash0_link`, `print_results_table`, `trap … EXIT` |
| `boilerplate/scenario-template.sh` | §2 of the plan, once per scenario | Status + body capture, `read_state` + `jq -e` assertion, `record_result` on both branches |
| `scripts/encode-dash0-link.py` | standalone reference (not inlined) | JSON state → URL-safe base64; documents the Dash0 query-state JSON shape used by `dash0_link` |

## Scope and writes

The skill itself performs exactly one write: the generated markdown plan file at the user-chosen path. Everything else — DB cleanups, config edits, spawning the service, catch-all listeners — is content baked **into** the plan, to be executed later by the user (or a follow-up agent with explicit authorisation).

Permissions needed at generation time:

| Tool | Purpose |
|---|---|
| `Read` / `Grep` / `Glob` | discover the API contract from the codebase (route handlers, request shape, auth, persistence) |
| `Write` | save the single plan markdown file |
| `Bash` | run `scripts/encode-dash0-link.py` (pure computation: JSON → URL-safe base64) |

No DB access, no network calls, no process spawning at generation time.

## When to use

Use this skill **after** the following are true:

- Implementation is complete on a feature branch.
- Unit and/or integration tests pass.
- The change exposes one or more HTTP / webhook / SNS-wrapped / OTLP-ish API endpoints.

A PR is optional. The skill produces value any time the user wants end-to-end manual validation, regardless of whether a PR is open yet.

### Hard prerequisites — the skill verifies these itself before generating

These two preconditions are the user's responsibility, NOT the plan's. The plan must NOT instruct the runner to set up env vars or start the service — only to verify the running state.

1. **`<service-dir>/.env.local` exists and is gitignored**, holding at minimum the OTel + Dash0 ingestion env vars plus whatever the service needs to authenticate to its persistence backend.
2. **The service is already running locally** with that env file sourced — i.e. the user ran `source .env.local && <start-command>` in their own shell before invoking the skill, and the service is listening on a known local port.

**Do NOT ask the user about these — check them yourself in the Preflight phase below.** Only stop and ask the user to fix something if a check fails.

Do NOT use this skill for:

- Pure UI flows (use a Playwright / browser-automation plan instead).
- Library / SDK changes with no API surface.
- Changes where there is no local-runnable service.

## What the skill produces

A single markdown file at a user-chosen path (default: `docs/test-plans/YYYY-MM-DD-<feature-slug>-manual-test-plan.md`) with this structure:

1. **Preamble** — "for agents" notice listing tool prerequisites and working directory.
2. **§0 Pre-flight** — infra-readiness checks, env-var bootstrap from a sourced file (e.g. `.env.local`), credential lookup from local persistence if needed, catch-all listeners for any async-response endpoints, and a **state-reset step** that soft-deletes leftover fixtures from previous runs.
3. **§1 Helpers** — sourced bash functions: request builders, request submitters, state readers. Parameterised so scenarios reduce to one-liners.
4. **§2 Scenarios** — N self-contained blocks. Each one re-exports a fresh fixture id, runs the request(s), and asserts via `jq -e '<predicate>'` or shell-comparison on captured state. **Fail-fast with `exit 1`** so the whole plan can run as a single bash invocation and any regression produces a non-zero exit.
5. **§3 Monitoring** — Dash0 traces + logs UI links scoped to the local service, with per-scenario sub-links when the test data permits isolation (e.g. by a fixture-id that's emitted as a span attribute).
6. **§4 Cleanup** — kill background listeners, optional infra teardown, optional persistence cleanup.

## Process

Two phases: **Preflight (auto-checks, no questions)** → **Interview (narrow, only for what the skill cannot infer)** → **Generate plan**.

### Preflight — auto-verify and auto-discover

Do these checks yourself. Do NOT ask the user about anything you can determine from the filesystem, local processes, or codebase. The user only ever needs to identify the service directory (sometimes obvious from cwd).

1. **Service directory.** If the user is already inside one (their `cwd`) or there's an obvious single service-dir in the repo, use it. Otherwise ask once.

2. **`.env.local` exists.** Use `Read` on `<service-dir>/.env.local`. On success → exists; on error → not present. If not present, stop and tell the user:

   > "I can't find `<service-dir>/.env.local`. The skill assumes you've already set up your local env. Create it (gitignored) with your service's auth secrets + OTel ingestion vars, then re-invoke."

3. **Read `.env.local` to extract context.** This file already holds the OTel + Dash0 vars **and** any local-service admin credentials the user wants to reuse across runs. Pull these without asking the user:

   Telemetry / UI link generation:
   - `OTEL_EXPORTER_OTLP_ENDPOINT` → derive the Dash0 ingress host → infer the matching app host (e.g. `app.dash0.com` ↔ `ingress.<region>.aws.dash0.com`, `app.dash0-dev.com` ↔ `ingress.<region>.aws.dash0-dev.com`).
   - `OTEL_EXPORTER_OTLP_HEADERS` → extract `Dash0-Dataset=<value>` and store as `DATASET`.
   - `OTEL_SERVICE_NAME` → store as the filter value used by the per-scenario Dash0 links.
   - `DASH0_ORG` (if present) → the org slug used in the generated URL's `?org=` param. **This is required for usable links.** If `.env.local` does not export `DASH0_ORG`, see step 5.
   - `DASH0_APP_HOST` (if present) → overrides the host inferred from the ingress endpoint.
   - `DASH0_AUTH_TOKEN` (if present) — never paste back into the plan; only used for the org-discovery curl in step 5.

   Local-service admin auth (for calling the service under test from scenarios):
   - **Any pre-exported auth env vars in `.env.local` are the source of truth.** Bearer-token candidates (in priority order — first match wins): `API_TOKEN`, `API_BEARER`, `LOCAL_API_BEARER`, `LOCAL_API_TOKEN`, plus any project-prefixed alias the user has (`<SERVICE>_API_TOKEN`, `<SERVICE>_BEARER`). Tenant-context candidates: `TENANT_ID`, `ORG_ID`, `ORG_TECHNICAL_ID`, plus any project-prefixed alias. Users frequently alias one canonical token under several names (e.g. `API_BEARER=$API_TOKEN`) — pick the first one defined, never insist on a particular name.
   - The plan should reference these env vars directly in §2 scenarios (`Authorization: Bearer $API_TOKEN`) — do NOT inline the token in markdown and do NOT re-ask the user.
   - **Only ask the user for auth if no `.env.local` export plausibly satisfies the route's auth requirement.** That includes: no token-shaped var, OR the route uses a fundamentally different identity (machine-token-only vs ui-token-only, mTLS, OAuth code grant) that the existing vars don't fit. In that case, tell the user which env var to add to `.env.local` so it sticks for next time.

4. **Service is reachable.** Determine the local port:
   - Look in the service's config files (`*.yaml`, `*.yml`, `Makefile`, `docker-compose.yml`, `.env*`) for a `listenAddress` / `PORT` / `port:` value.
   - Fall back: probe known common ports (8000, 8002, 8080, 3000) with `curl -fsS http://localhost:<port>/`.
   - The healthcheck does NOT need to be a `/healthcheck` route. Any HTTP response (200, 404, or even a known route returning a JSON error) confirms the service is listening. Connection-refused = not running.

   If not running, stop and tell the user:

   > "The service isn't responding on `http://localhost:<port>`. Start it yourself in a shell that has sourced `.env.local`, then re-invoke."

5. **Dash0 org slug (for the UI link's `?org=` param).** The link's `?org=` param must be a **real Dash0 org slug** — `Organization not found` is what the UI shows when this is wrong. Resolve it in this order:
   1. `DASH0_ORG` exported in `.env.local` → use it verbatim.
   2. Otherwise, attempt one curl against the Dash0 API with the auth token to look up the org (only if you actually know the endpoint for this deployment — do NOT guess one).
   3. Otherwise, **ask the user once** with this exact question: `What is your Dash0 org slug (the value in the URL after ?org=)?`. Suggest they add `export DASH0_ORG=<value>` to `.env.local` so it sticks for next time.

   **You MUST NOT invent an org slug.** Never derive it from `OTEL_SERVICE_NAME`, the user's name, the ticket id, the branch name, or any other string in the environment. The placeholder `<your-org-slug>` must be replaced with a real, user-confirmed value before the plan is written — otherwise every link in the table 404s.

   **`DASH0_ORG` is NOT the same thing as a test-fixture "organization-id" field.** Many features (AWS CloudFormation integrations, multi-tenancy webhooks, billing fixtures, etc.) accept an `organizationId` / `OrganizationId` / `OrgSlug` / `TenantId` parameter on the **request payload** or **CF template parameters**. That value is owned by the scenario and is usually a throwaway test string (e.g. `test-tenant-id`, `<feature>-test-org`). It lives in §2 scenarios, never in §1 helpers or §3 link generation. Keep them strictly separated:

   | What | Where | Example | Notes |
   |---|---|---|---|
   | `DASH0_ORG` | §1 helpers, used by `dash0_link` | `your-org-slug` (the value after `?org=` in any working Dash0 UI URL you've opened) | Real org slug from `.env.local`. Goes into `?org=...` in the UI URL. |
   | Test-fixture org id | §2 scenario payloads / CF params | `test-tenant-id` (any throwaway string) | Synthetic. Goes into the request body / template parameters. NEVER into the Dash0 UI URL. |

   If both exist in the same plan, name them so they're never confused at a glance — e.g. `DASH0_ORG` vs `TEST_ORG_ID`. Never use one for the other.

6. **Auto-discover from the codebase** (no questions):
   - **API surface.** Grep for route registrations in the changed files (or in `internal/routes/`, `handlers/`, etc.). Read the matching handler functions to determine: endpoint paths, methods, wire format (plain JSON / SNS-wrapped / form-data / gRPC), auth scheme (Bearer / body-embedded / mTLS), and response shape.
   - **Uniqueness constraints.** Grep migrations / schema files for `UNIQUE` indexes that match the resource being tested.
   - **Async callback URLs.** If route handlers PUT or POST back to a customer-supplied URL field, the plan needs a catch-all listener.
   - **Config knobs that affect tests.** If the change introduces a timeout / TTL / poll-interval, identify the config name so the plan's preflight can read it.

After Preflight, you should have answers to: service dir, port, healthcheck route, dataset, app host, org slug, service.name, all the endpoint and wire-format details, uniqueness constraints, and async-callback needs. Ask the user only for what's left.

### Interview — only what couldn't be inferred

Open a tight Q&A for the gaps. Typical residue:

1. **Feature context** — ticket / branch / one-line description, design-spec or PR URL (the user has these; you don't).
2. **Scenarios** — accept the user's list OR derive from the design spec / PR's "test plan" checklist. Families to suggest when relevant:
   - **Happy path** — canonical Create with all required fields.
   - **Partial state / intermediate path** — for state-machine features, exercise each transition.
   - **Timeout / async-completion path** — if the feature has a watchdog/deadline, short-circuit it via a config knob (seconds, not minutes).
   - **Recovery / idempotency** — if the feature handles late events after a terminal state.
   - **Delete / cancellation** — the lifecycle endpoint.
   - **Update / mutation that changes invariants** — e.g. widening or narrowing a set.
   - **Input validation rejection** — bad input returns 4xx with a specific reason in the body. Use the explicit `curl -o body_file -w '%{http_code}'` pattern — the `curl -i | awk` body splitter is fragile against CRLF responses.
3. **Per-scenario discriminator** — which attribute key Dash0 sees on every span/log that uniquely identifies a scenario's request flow. Common: a fixture ID emitted under a stable semconv key like `<service>.resource.id`. If only one attribute appears on the spans, no question needed.

Anything you didn't cover in Preflight goes here. Anything Preflight already answered does NOT.

## Plan-document template

After the interview, write the document. The exact structure below mirrors what's worked in production runs.

### Preamble

```markdown
# <feature> — Manual Test Plan

> **For agents:** Runnable end-to-end against a service the user has already started locally. The plan does NOT start the service or set env vars — those are prerequisites the user owns.
>
> **Hard prerequisites (verify before running):**
> 1. `<service-dir>/.env.local` exists with OTel + Dash0 ingestion vars + service-specific secrets.
> 2. The service was started in a shell where that env file was sourced (`source .env.local && <start-command>`).
> 3. The service is currently reachable on its local port.
>
> Requirements: bash/zsh, `jq`, `uuidgen`, `curl`. (No `docker compose up`, no `make run`. Just the validators + scenarios.)
>
> Work from: `<absolute path to service dir>`.
```

### §0 Pre-flight (verification + per-test-run setup — never starts the service)

#### 0.1 Verify prerequisites

`Read` `boilerplate/preflight-service-check.sh` and inline it verbatim, substituting `<service-dir>`, `<healthcheck-or-known-200-endpoint>`, `<port>`, and `<start-command>`. After that block, if the feature has a configurable timeout normally measured in minutes, append a `<read-current-timeout-from-config-and-warn-if-too-large>` check so the runner sees the live config value before scenarios run.

#### 0.2 Start catch-all listener (only if any endpoint emits a customer-supplied callback URL)

`Read` `boilerplate/catchall.sh` and inline it verbatim. It writes `/tmp/catchall.py` (a tiny HTTP server that 200s every verb on :9999), launches it via `nohup`, exports `CATCHALL_PID`, and waits for it to come up. **Required** when any handler PUTs/POSTs back to a customer-supplied URL (e.g. CloudFormation `ResponseURL`); skip the section otherwise.

#### 0.3 Resolve runtime credentials

**First choice: reuse env vars from `.env.local`.** If Preflight found pre-exported auth vars (e.g. `API_TOKEN`, `API_BEARER`, `TENANT_ID`, `ORG_ID`, or any project-prefixed alias), reference them directly in §2 scenarios via `$VARNAME`. The plan asserts they are non-empty in §0.6 and otherwise does nothing — the user already set them when they sourced `.env.local`. **Do not paste the actual values into the markdown; do not re-prompt the user for them.**

**Fallback: query local persistence.** If the route needs credentials that don't fit any env var (e.g. a per-scenario API key the service issues), show the SQL/curl/etc. the runner should execute to fetch one at runtime. Use a placeholder the user fills in, or capture into a shell variable. Never inline secrets in markdown.

#### 0.4 Static test-context env

```bash
# Anything that doesn't change per-scenario.
export <STATIC_VAR_1>=...
export <STATIC_VAR_2>=...
export <RESPONSE_URL>=http://localhost:9999/
```

#### 0.5 State reset

**Required** if the API enforces uniqueness on any tuple that test scenarios re-use. Without this, the first run of the plan passes but every subsequent run fails because of a leftover row. SQL example:

```bash
DB_CID=$(docker ps --filter "name=<db-container>" -q)
docker exec "$DB_CID" psql -U <user> -d <db> -c \
  "UPDATE <table> SET deleted_at = now() WHERE deleted_at IS NULL AND <discriminator>;"
```

#### 0.6 Sanity assert

```bash
echo "endpoint=$OTEL_EXPORTER_OTLP_ENDPOINT  service=$OTEL_SERVICE_NAME"
test -n "$<REQUIRED_VAR_1>" -a -n "$<REQUIRED_VAR_2>" -a -n "$SERVICE_PID" \
  || { echo "✗ pre-flight failed"; exit 1; }
```

### §1 Helpers

Define request-builder, request-poster, state-reader, and results-recorder as bash functions. Parameterise everything per-scenario. Key patterns:

- `request_envelope <inner_json>` — wraps a business payload in the wire envelope (webhook-style, OTLP, etc.).
- `post_request <envelope>` — POSTs and returns the FULL `curl -i` output. Add `| head -1` only when you care about the status line; for body inspection use `-o file -w '%{http_code}'`.
- `<resource>_payload <RequestType> [json-array-of-params...]` — generates the business payload, parameterised by RequestType and discriminator fields.
- `read_state` — queries the side-effect surface (DB row, downstream API, file) and emits a one-line JSON snapshot. Use `jq` to project only the fields you'll assert on.
- `new_fixture_id <scenario-name>` — exports a fresh unique ID per scenario so they never collide.
- `record_result <name> <PASS|FAIL> <http-code> <outcome-text> <discriminator>` — appends one row to `$RESULTS_TSV`. Five fields, all required. Called at the end of every scenario.
- `dash0_link <traces|logs> <discriminator>` — emits a Dash0 URL pre-filtered to `service.name=$OTEL_SERVICE_NAME` AND `<DISCRIMINATOR_KEY> is <discriminator>`. Pure inline Python, no external script.
- `print_results_table` — bound to `trap … EXIT` so it fires even on fail-fast exits.

### Results-table contract (MANDATORY — do not drop columns)

Every generated plan **MUST** end its run with this six-column table, printed via the helper below. The Traces + Logs columns are required — they are the entire point of the skill. If you find yourself omitting them, your generated plan is broken.

```
| # | Scenario | Status | HTTP | Outcome | Traces | Logs |
```

- **#** — sequence number
- **Scenario** — human-readable name (matches the section header)
- **Status** — `✓ PASS` / `✗ FAIL`
- **HTTP** — last response status code observed by the scenario (e.g. `200`, `400`, `401`)
- **Outcome** — one-sentence human description of what the assertion verified (e.g. `stamped completed, lastVerifiedAt set`)
- **Traces** — `[open](https://<dash0-app-host>/traces/explorer?...)` deep-link, pre-filtered to `service.name=<local>` AND `<discriminator-key> is <fixture-id>`
- **Logs** — `[open](https://<dash0-app-host>/logs?...)` deep-link with the same filter

### Boilerplate to drop into §1 of every generated plan

`Read` `boilerplate/results-table.sh` and inline it verbatim inside the §1 helpers block. It defines:

- `RESULTS_TSV` (portable mktemp template, X's at end of basename — see the in-file comment for why `/tmp/foo-XXXXXX.tsv` is broken),
- A placeholder-guard loop that aborts the plan if `DASH0_APP_HOST` / `DASH0_ORG` / `DISCRIMINATOR_KEY` still look like `<...>` or contain `your-`,
- `record_result <name> <PASS|FAIL> <http> <outcome> <disc>` — appends one TSV row,
- `dash0_link <traces|logs> <disc>` — emits a fully-formed Dash0 UI URL,
- `print_results_table` — bound via `trap … EXIT` so the table prints even on fail-fast.

`DISCRIMINATOR_KEY` defaults to the attribute the service already emits on every span/log for the resource being tested. Pick any stable semconv-style key that's present on the spans for one test run and absent on others — common shapes: a resource ID (`<resource>.id`), a request/transaction ID, or a feature-specific fixture key the handler tags onto spans. The plan-generator MUST replace the `<attribute-key>` placeholder with the actual key before saving the plan (otherwise the placeholder-guard trips at runtime).

### §2 Scenarios (one block per scenario)

`Read` `boilerplate/scenario-template.sh` and inline it once per scenario, substituting the `<scenario>`, `<name>`, `N`, `<url>`, `payload …` call, `<assertion-predicate>`, and outcome strings. The template captures HTTP status + body separately (the only pattern that works across CRLF + varying response shapes), reads side-effect state via `read_state`, asserts with `jq -e`, and calls `record_result` on **both** branches with all five fields so the final table shows the full picture even on fail-fast.

Notes:

- `$FIXTURE_ID` is exported by `new_fixture_id` and holds the discriminator value (e.g. the full stack ARN, a UUID, etc.) that `dash0_link` will inject into the per-scenario filter.
- The 4th arg to `record_result` (outcome description) becomes the **Outcome** cell in the table. Write it as a short sentence describing what the assertion actually verified — e.g. `"row=completed, lastVerifiedAt stamped"`, `"reason names the malformed entry"`, `"4xx rejection with expected message"`. Avoid tabs.
- For scenarios where the assertion is just "expected HTTP code", outcome can be the same sentence on both branches.

Per-scenario state reset between scenarios is required when uniqueness constraints exist. Either run `clean_state` at the top of every scenario OR use a different discriminator value per scenario.

### §3 Monitoring — Dash0 links

Generate trace + log links using the encoder script (`scripts/encode-dash0-link.py` in this skill's directory). The query state is `org`, `dataset`, time-window, sampling, plus a `filter` array with `service.name is <local>` AND a per-scenario discriminator.

Important caveats from real runs:

- The `contains` operator is not reliably accepted by the Dash0 app's URL query parser depending on the schema version — some versions throw a React Server Components error on render. **Default to `is` with an exact value.** If you want fuzzy matching across scenarios, generate the link after the run using the just-created fixture ID.
- The link's `s` parameter is `urlsafe_base64(zlib.compress(json_state))`. The encoder script bundled with this skill does exactly that.

### §4 Cleanup

```bash
kill "$CATCHALL_PID" "$SERVICE_PID" 2>/dev/null || true
# Optional: tear down infra (docker compose down)
# Optional: re-soft-delete the test fixtures
```

## Output handoff

When the plan is written:

1. Save to the user-chosen path (default: `docs/test-plans/YYYY-MM-DD-<feature-slug>-manual-test-plan.md`).
2. Tell the user how to execute it: the service is already running (per the hard prerequisites), so the executor just runs the saved plan as a shell script. For example: `bash <plan-file>` from inside `<service-dir>`. Or step-through each section.
3. Offer to dispatch a sub-agent to execute it. Recommend running all scenarios in one bash invocation with fail-fast assertions — that produces a clean PASS/FAIL summary in seconds for cheap scenarios, or minutes if there's a real wait-for-timeout step.
4. The executor sees the per-scenario results table (with Dash0 trace + log links) printed at the end of the run via the `trap 'print_results_table' EXIT` handler in §1.

## What the skill does NOT do

By design, this skill does not:

- Create or edit a `.env.local` file. That is the user's setup — the skill assumes it exists and contains working credentials.
- Start, restart, or modify the running service. Verification only.
- Set OTel env vars or troubleshoot ingestion. If telemetry is broken, the user fixes their setup before invoking this skill again.
- Mint Dash0 auth tokens, change org/dataset config, or touch anything in the Dash0 UI other than open the generated links.

These exclusions are what keep the skill's permission surface minimal (`Read`, `Grep`, `Glob`, `Write`, `Bash` restricted to the encoder script).
