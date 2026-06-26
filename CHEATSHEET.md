# Engineering cheat sheet

Onboarding notes for a colleague joining this codebase. Skim top-to-bottom
once, then keep open as a reference.

> Full deploy commands live in [README.md](README.md). This doc explains
> **how the system works**, not how to deploy it.

## The 30-second version

Two flows; understand both and you've understood the system.

**Ingestion (always on, in the background):**

    EventBridge ──► Firehose ──► S3 (raw, partitioned by date)
                ──► Enrichment Lambda ──► S3 (enriched/, flat JSON)
    Glue catalogs the S3 prefixes; Athena queries them.

**Read (every dashboard page load):**

    Browser ──► Vite dev server (signs SigV4) ──► API Gateway (AWS_IAM)
            ──► Stats Lambda ──► (Athena | CodePipeline APIs | STS AssumeRole)
            ──► JSON ──► Browser renders cards

There is no hosted version of the UI. It runs on `localhost:5173` against
a live AWS backend.

---

## Backend: the two Lambdas

| Lambda | Triggered by | What it does | Code |
|---|---|---|---|
| **Enrichment** | EventBridge (every CodePipeline/CodeBuild state change) | Calls `GetPipelineExecution`/`ListActionExecutions`/`BatchGetBuilds`, builds a flat JSON record, writes to `s3://<data-lake>/enriched/{pipeline-executions,build-details}/year=…/month=…/day=…/` | `terraform/dashboard-backend/lambda/enrichment/index.py` |
| **Stats** | API Gateway (when the dashboard calls `/stats`, `/pipelines`, `/accounts`) | Routes on `event['routeKey']`, then queries Athena (`/stats`) or fans out to `codepipeline:ListPipelines` + tracked accounts (`/pipelines`) | `terraform/dashboard-backend/lambda/stats/index.py` |

Both share one IAM role each. Look at `terraform/dashboard-backend/main.tf`
for the inline policy documents — search for `enrichment_lambda` and
`stats_lambda`.

### What's in S3

```
s3://pipeline-dashboard-data-<acct>/
├── pipeline-events/year=YYYY/month=MM/day=DD/*.json    ← raw EventBridge events (Firehose)
├── build-events/year=YYYY/month=MM/day=DD/*.json       ← raw EventBridge events (Firehose)
├── enriched/pipeline-executions/year=…/{execId}.json   ← enrichment Lambda output
├── enriched/build-details/year=…/{buildId}.json        ← enrichment Lambda output
├── athena-results/                                     ← scratch, ignore
└── errors/{pipeline,build}-events/                     ← Firehose write failures
```

The Glue catalog (`pipeline_dashboard_db`) has 4 tables — one per prefix
above (raw + enriched, for pipelines + builds). The stats Lambda only
queries the **enriched** tables because they're flat and cheap to scan.
The raw tables exist for forensic queries you'd run by hand in Athena.

### Why two paths (raw + enriched)?

Cost vs. flexibility. Firehose-to-S3 is pennies per million events and runs
unconditionally. The enrichment Lambda costs more per event (it makes extra
API calls) and writes only on terminal states (`SUCCEEDED`/`FAILED`/`CANCELED`/
`SUPERSEDED`). If the Lambda is broken, you still have the full raw archive.
If the archive bucket is wiped, the dashboard still works because it reads
the enriched prefix.

---

## API: 3 routes, all `AWS_IAM`-protected

API Gateway is HTTP API v2 (not REST). Configured in
`terraform/modules/api_gateway/main.tf`. CFN equivalent at
`cloudformation/dashboard-backend/template.yaml` (`StatsApi` resource).

| Route | Returns | Backed by |
|---|---|---|
| `GET /stats` | `{ total, running, failed24h, successRate, runs24h }` | Athena (single multi-CTE query) |
| `GET /pipelines` | `{ pipelines: [...], errors: [...] }` | `codepipeline:ListPipelines` per account, enriched with `GetPipeline`/`GetPipelineState`/`ListPipelineExecutions` |
| `GET /accounts` | `[{ id, alias, region }, ...]` | Local account + `tracked_accounts` env var + (optional) `organizations:ListAccounts` |

Every route has `AuthorizationType: AWS_IAM`. Unsigned calls get `HTTP 403`.
There is no per-user identity inside the Lambda — `event['requestContext']`
doesn't carry anything useful for authorization, only for routing. Authn
and authz both live at the API Gateway layer.

CORS is set per-API (allow origin `http://localhost:5173` by default). The
browser doesn't actually do cross-origin requests in practice because the
Vite proxy is same-origin — CORS only matters if you debug the API from
DevTools directly.

---

## Frontend: tiny by design

- **`dashboard/src/main.jsx`** — React entrypoint, renders `<App />`.
- **`dashboard/src/App.jsx`** — All UI (cards, filters, charts). Calls only
  `pipelineService.js`. **No `fetch()` in here.** Project convention.
- **`dashboard/src/pipelineService.js`** — The single seam between UI and
  backend. `listAccounts()`, `listAllPipelines(accountIds)`, `getStats()`.
  Three functions, ~30 lines each. Read this file first when picking up
  data-shape questions.
- **`dashboard/vite.config.js`** — Defines the `aws-sigv4-proxy` plugin.
  This is the most important file in the frontend.

### How the SigV4 proxy works

`vite.config.js` registers a Vite middleware that mounts on `/api`. When
the browser issues `fetch('/api/accounts')`:

1. Vite catches the request server-side (same-origin from the browser's
   perspective).
2. The middleware loads AWS credentials via `@aws-sdk/credential-provider-node`
   on the developer's machine — environment variables, `~/.aws/credentials`,
   AWS IAM Identity Center, whatever's in the standard chain.
3. It rebuilds the request as `https://<api-id>.execute-api.<region>.amazonaws.com/accounts`,
   signs it with `SignatureV4` (service `execute-api`), and pipes the response
   back to the browser.
4. The browser sees a plain `200 OK` with JSON. No credentials in the page.

If you change the API URL, update `VITE_API_URL` in `dashboard/.env`.
Restart the Vite dev server so it re-reads the env.

The proxy is the reason the API can stay `AWS_IAM`-protected without
shipping any auth code in the React app.

---

## Request lifecycle — full trace of `GET /pipelines`

Concrete example so you can follow it through tomorrow's debugging session:

```
1.  Browser:    fetch('/api/pipelines') from src/pipelineService.js
2.  Vite:       middleware at vite.config.js#awsSigV4Proxy receives it,
                builds an HttpRequest for https://<api-id>.execute-api.<region>.amazonaws.com/pipelines,
                signs with SigV4 using local creds, forwards.
3.  API GW:     route GET /pipelines matches; AuthorizationType=AWS_IAM
                verifies SigV4 + checks the caller has execute-api:Invoke
                on this route's ARN. 403 if not.
4.  Lambda:     pipeline-dashboard-stats invoked.
                handler() inspects event['routeKey'] -> handle_pipelines().
                For the local account: codepipeline:ListPipelines, then
                build_pipeline_row() per pipeline (which itself calls
                GetPipeline + GetPipelineState + ListPipelineExecutions).
                For each entry in _effective_tracked_accounts() that has a
                role_arn: sts:AssumeRole, then the same fan-out using a
                client built from the temporary creds.
                For synthetic entries: clone the local rows, perturb status.
                Returns { pipelines: [...], errors: [...] }.
5.  API GW:     200 → Vite middleware streams body back.
6.  Browser:    pipelineService.normalizePipeline() fills in missing fields
                with safe defaults so App.jsx can call .map/.filter freely.
7.  App.jsx:    renders cards.
```

Look at `event['requestContext']` in CloudWatch logs to see which IAM
principal made the call — the userArn shows up under `authorizer.iam`.

---

## Multi-account: two modes

Both modes end with the central stats Lambda calling
`sts:AssumeRole` into target accounts. The difference is **how the role
gets created** in those accounts.

### Per-account mode (`tracked_accounts`)

- `make track-account PROFILE=<…> ALIAS=<…>` runs `terraform apply` against
  `terraform/cross-account-reader/` using the target profile. Creates a
  `PipelineDashboardReader` role trusted by the central stats Lambda role.
- Then appends the new entry to the central stack's `tracked_accounts`
  variable and re-applies the dashboard backend.
- Good for: a handful of named accounts.

### Organizations mode (`tracked_organization.enabled = true`)

- Central stack deploys a CloudFormation StackSet (service-managed) that
  pushes the reader role into every account in your org's specified OUs.
- New accounts onboarded into those OUs auto-receive the role.
- Stats Lambda calls `organizations:ListAccounts` on each request,
  filters out the local account + `ORG_EXCLUDE_ACCOUNTS`, expands across
  configured regions, assumes the role in each.
- The `AssumeRole` IAM statement is constrained by
  `aws:ResourceOrgID == <our org id>`, so even if someone outside the org
  creates a role of the same name, the Lambda can't be tricked into
  assuming it.

The org account list is **cached for 60s** inside the Lambda warm container
(see `_org_account_cache` in `stats/index.py`). Don't be surprised if a
freshly-added account takes up to a minute to show up.

### Synthetic accounts (`synthetic_account_count`)

Pure demo feature. Set to a non-zero number and the Lambda clones the
local account's pipelines under N fake account IDs (different aliases +
regions, perturbed statuses) so the multi-account UI has volume to show.
Production deploys should leave it at 0.

---

## Where things live

| You want to change… | Edit this |
|---|---|
| How pipelines look in the UI (cards, columns, charts) | `dashboard/src/App.jsx` |
| The data shape the UI expects | `dashboard/src/pipelineService.js` → `normalizePipeline` |
| What `/stats` aggregates | `lambda/stats/index.py` → `handle_stats` (SQL inside) |
| How a pipeline row is built | `lambda/stats/index.py` → `build_pipeline_row` |
| What the enrichment writes to S3 | `lambda/enrichment/index.py` |
| API routes / auth | `terraform/modules/api_gateway/main.tf` |
| Lambda IAM permissions | `terraform/dashboard-backend/main.tf` (look for `data "aws_iam_policy_document"`) |
| EventBridge filters | `terraform/dashboard-backend/main.tf` → `*_events_rule` modules |
| CFN mirror of any of the above | `cloudformation/dashboard-backend/template.yaml` |
| Demo pipelines used for testing | `terraform/sample-pipelines/` |

---

## Troubleshooting cheat list

| Symptom | First place to look |
|---|---|
| Dashboard shows "No accounts" | `aws logs tail /aws/lambda/pipeline-dashboard-stats --since 5m` — Athena query failed? AssumeRole denied? |
| Browser network tab shows `GET /api/accounts` returning HTML | Vite proxy didn't mount. Restart `make run-dashboard`. Most common cause: a Vite config file edit failed mid-restart (see `vite.config.js`). |
| `403` on every API call | Either (a) your IAM principal doesn't have `execute-api:Invoke` on the API — attach the policy from the deploy outputs, or (b) AWS creds aren't loaded in the shell that's running Vite. |
| `503` / `500` on `/stats` | Athena query failed. Check the workgroup `pipeline-dashboard-workgroup`'s query history in the console. Most common: enriched tables empty because nothing has run yet. |
| Pipelines from another account missing | Check `_list_organization_accounts` cache (60s TTL), check the reader role exists in that account, check `aws:ResourceOrgID` condition didn't fail (target account is in a different org). |
| Enrichment data not appearing | DLQ alarm fired? `aws sqs receive-message --queue-url <enrichment-dlq-url>`. The Lambda swallows most errors and writes them to logs — `aws logs tail /aws/lambda/pipeline-dashboard-enrichment`. |

---

## House rules (from `.kiro/steering/project-conventions.md`)

- Always go through the **Makefile**. Don't invent new `terraform apply` /
  `aws cloudformation deploy` invocations.
- `terraform fmt` (or `make tf-fmt`) before committing TF changes.
- API calls in **`pipelineService.js` only** — never `fetch()` in `App.jsx`.
- `VITE_API_URL` comes from `dashboard/.env` at build time. Never hardcode.
- Never commit `.env`, `*.tfvars`, or `terraform.tfstate*` — gitignored.

## Going deeper

- `README.md` — top-level overview + deploy commands
- `cloudformation/README.md` — CFN-specific notes + differences from TF
- `terraform/sample-pipelines/README.md` — how the demo pipelines work
- `.kiro/steering/project-conventions.md` — binding style rules (local-only)
