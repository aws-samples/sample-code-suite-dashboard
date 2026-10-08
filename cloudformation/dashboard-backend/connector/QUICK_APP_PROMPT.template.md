# Quick App build prompt — AWS Code Suite dashboard

Paste the sections below into the **Amazon Quick app builder** to recreate the
dashboard as an app in Quick, backed by the connector you deployed. This is a
template; run `docs/../scripts/render_quick_app.py` (see repo) to produce a copy
with your live values filled in.

> Build in phases, one prompt block at a time, and verify each before moving on.
> The Quick agent loses accuracy in long single prompts, so do not paste the
> whole file at once.

---

## Prerequisites (do these in the Quick console first)

Connectors → Create for your team → **OpenAPI Specification**, then import
`openapi.generated.json`. The console form asks for these; notes reflect the
console's validation rules (learned the hard way):

1. **Description** (required). Only these characters are allowed: letters,
   numbers, spaces, `_ . , ! ? -`. No slashes, colons, parentheses, or em
   dashes. A safe value:
   `Read-only connector for the AWS Code Suite Dashboard.`
2. **Base URL** (required). Must be the connector base *including* the
   `/connector` suffix, no trailing slash:
   `{{CONNECTOR_BASE_URL}}`
   Paste it (don't type) to avoid a typo in the API id, or every action 404s.
3. **Authentication:** Service authentication → OAuth2 client credentials.
   The scope field appears on THIS step, not the spec page.
   - Token URL: `{{CONNECTOR_TOKEN_URL}}`
   - Client ID: `{{CONNECTOR_CLIENT_ID}}`
   - Client secret: *(fetch from Cognito; not stored in this repo — see runbook step 5)*
   - Scope: `{{CONNECTOR_SCOPE}}` (enter exactly, with the `/`)
4. **Publish / sharing — "Everyone in your organization?"** This connector uses
   service-to-service auth, so all users share one service credential and see
   the same data (no per-user filtering). It returns read-only pipeline/build
   metadata (names, statuses, durations, account ids). **Org-wide is a
   reasonable default** unless your pipeline/account names themselves are
   sensitive, or you later add actions that return logs/secrets — then restrict
   it. It also cannot be used in Chat or Flows (expected; we use it in an App).
5. Confirm the four actions appear: `getStats`, `getAccounts`, `getPipelines`,
   `getPipeline`.

---

## Phase 0 — Visual reference (read this first)

> **Prompt-only is the primary path** — you do NOT need to attach or import any
> files. There is no code import into Quick, and the phases below already carry
> the design tokens, layout, data shapes, and which connector action feeds each
> view. Just paste the phases in order; the agent generates its own
> implementation that is **as close as possible** to the reference, not a
> byte-for-byte copy.
>
> The reference implementation lives at **`dashboard/src/App.jsx`** in this repo
> (the full dashboard UI: cards, stat tiles, stage stepper, sparkline, account
> switcher). `dashboard/src/ChatDrawer.jsx` is the chat drawer, out of scope for
> v1 (see Teardown/Notes).
>
> **Optional fidelity boost:** if a specific view comes out looking off, open
> `App.jsx` locally and paste the relevant snippet as a targeted follow-up for
> just that piece — surgical, not the whole file. Treat `App.jsx` as the design
> spec, not as importable source.

Design tokens taken from that file (AWS Cloudscape-like):

- Text `#16191f`, secondary `#5f6b7a`, muted `#7d8998`, link `#0972d3`.
- Surfaces white on `#f7f8f8`; hairline borders `#e9ebed`.
- Primary action / accent orange `#ec7211` (hover `#d96813`).
- Status colors: Succeeded `#037f0c`, InProgress `#0073bb`, Failed `#d91515`,
  Stopped `#5f6b7a`.
- Dense, data-first layout; small type (12–13px body, 28px stat numbers);
  monospace tabular numerals for versions, durations, timestamps.

---

## Two ways to build

- **Option A - Single prompt (fastest):** paste the one combined prompt below
  and let the agent build the whole app at once. Good for this 3-view dashboard;
  verify the result end to end.
- **Option B - Phased (most reliable):** paste Phase 1, 2, 3 one at a time,
  verifying each. Amazon Quick's docs note the agent loses accuracy on long
  prompts and recommend phasing for complex apps, so fall back to this if the
  single prompt comes out incomplete, mocks data, or gets a view wrong.

Both produce the same app. Start with A; drop to B if A disappoints.

---

## Option A - Single prompt

> Build a pipeline observability dashboard titled "CodeDashboard", using my
> connector actions `getStats`, `getAccounts`, `getPipelines`, and `getPipeline`
> for all data - do not mock or hardcode any data. Use a light, data-dense AWS
> Cloudscape-style layout: white cards on a `#f7f8f8` background, hairline
> `#e9ebed` borders, text `#16191f`, links `#0972d3`, accent orange `#ec7211`.
> Status colors: Succeeded `#037f0c`, InProgress `#0073bb`, Failed `#d91515`,
> Stopped `#5f6b7a`. Small type (12-13px body, 28px stat numbers), monospace
> tabular numerals for versions, durations, and timestamps.
>
> (1) Overview: a row of four stat tiles from `getStats` - Total pipelines
> (`total`), Running (`running`, blue), Failed 24h (`failed24h`, red), Success
> rate (`successRate`, green, as a percentage with `runs24h` as the subtitle "N
> runs in last 24h"). Refresh every 30s with an "updated Ns ago" indicator and a
> manual refresh. Handle loading (skeleton), empty (zero state), and error
> (non-blocking banner, keep last good values).
>
> (2) Pipelines list: cards from `getPipelines`, paginated via `pageSize` (25)
> and `nextToken` with a "Load more" control; show "N accounts unreachable" when
> `errorCount` > 0. Each card: `name` as a bold link to `logsUrl` (new tab); an
> account chip (`accountAlias` + last segment of `accountId`); `repository`
> (monospace) and a `branch` tag; a status badge from `status` (InProgress
> pulses); a trigger label from `triggerType` (GitTag = "Git tag push",
> BranchMerge = "Branch merge", Manual = "Manual run", Schedule = "Scheduled");
> a three-up row of Version (`version`), Last run (relative time from
> `lastRunStart` epoch ms), Duration (`durationMs` as m/s); and a "Stages" strip
> of `stageCount` segments. Add an account filter (`accountId`) and a status
> filter (`status`); make the "Failed 24h" tile click through to the Failed
> filter.
>
> (3) Pipeline detail: when a card is opened, call `getPipeline` with its
> `accountId` and `name` and show a stage stepper (ordered `stages`, colored by
> status, each linking to its `url` when present), a run-history sparkline (from
> `history`, oldest first, colored by status, sized by `durationMs`), and a
> success-rate summary (Succeeded / total from `history`). Keep it visually
> consistent with the cards.

Verify end to end: real numbers in the tiles, three pipeline cards with real
versions/durations, filters work, and a pipeline opens to show stages + history.
If any part is missing or shows mocked data, rebuild that part with the matching
phase below.

---

## Option B - Phased build

### Phase 1 - App shell + Overview

> Build a pipeline observability dashboard titled "CodeDashboard".
> Use a light,
> data-dense Cloudscape-style layout: white cards on a `#f7f8f8` background,
> hairline `#e9ebed` borders, text `#16191f`, links `#0972d3`, accent `#ec7211`.
>
> At the top, show an **Overview** row of four stat tiles using the `getStats`
> action: Total pipelines (`total`), Running (`running`, blue), Failed 24h
> (`failed24h`, red), Success rate (`successRate`, green, shown as a percentage
> with `runs24h` as the subtitle "N runs in last 24h"). Big 28px tabular
> numbers. Refresh `getStats` every 30 seconds and show a subtle "updated Ns
> ago" indicator with a manual refresh control.
>
> Handle loading, empty, and error states explicitly: a skeleton while first
> loading, a neutral empty state when counts are zero, and a non-blocking
> warning banner if the action errors (keep showing the last good values).

Verify the four tiles render and refresh before continuing.

---

### Phase 2 - Pipelines list

> Below the Overview, add a **Pipelines** section that lists pipelines from the
> `getPipelines` action as cards (one per pipeline). Paginate with the action's
> `pageSize` (use 25) and `nextToken`; load more on scroll or a "Load more"
> control. Show `errorCount` as a small "N accounts unreachable" note when > 0.
>
> Each card shows:
> - Pipeline `name` as a bold link to `logsUrl` (opens in a new tab).
> - An account chip from `accountAlias` + the last segment of `accountId`.
> - `repository` in monospace and a `branch` tag.
> - A status badge driven by `status` (Succeeded/InProgress/Failed/Stopped)
>   using the status colors above; InProgress pulses.
> - A trigger label from `triggerType` (GitTag = "Git tag push",
>   BranchMerge = "Branch merge", Manual = "Manual run", Schedule = "Scheduled").
> - A three-up row: Version (`version`), Last run (relative time from
>   `lastRunStart` epoch ms), Duration (`durationMs` formatted m/s).
> - A "Stages" strip showing `stageCount` segments (see Phase 3 for the real
>   per-stage detail).
>
> Add filter controls that map to the action parameters: an account filter
> (`accountId`) and a status filter (`status` = Succeeded/InProgress/Failed/
> Stopped). Make the Overview "Failed 24h" tile clickable to apply the Failed
> status filter, mirroring the reference UI.

Verify the list renders, filters work, and pagination advances.

---

### Phase 3 - Pipeline detail (stages + history)

> When a pipeline card is opened, call `getPipeline` with its `accountId` and
> `name` to load detail. Render:
> - A **stage stepper**: an ordered row of the `stages` array, each showing the
>   stage `name` and a bar colored by stage `status`; link each stage to its
>   `url` when present (opens in a new tab).
> - A **run history sparkline**: a small bar chart from the `history` array
>   (oldest first), each bar colored by `status` (green/red/grey) and sized by
>   `durationMs`; tooltip shows status and relative run index.
> - A success-rate summary computed from `history` (succeeded / total).
>
> Keep the detail view visually consistent with the card (same tokens, same
> status colors).

Verify a pipeline opens and shows real stages + history.

---

---

## Teardown — deleting the Quick app when you're done

The AWS backend has a scripted destroy (`scripts/destroy_backend.sh`), but the
Quick app + connector have **no delete API** — remove them by hand in the Quick
console. Do this before tearing down the backend stack.

1. **Delete the app:** open the app → **App settings → Overview → Delete**.
2. **Delete the connector:** Quick console → **Connectors** → open the OpenAPI
   connector you imported → **Delete** (deleting the app does not remove it).

That returns your Quick account to a clean state. Then, if you also want the
AWS side gone, run the backend teardown — see
[`../CONNECTOR_TEARDOWN.md`](../CONNECTOR_TEARDOWN.md) for the full sequence
(it deletes the CloudFormation stacks and empties their S3 buckets).

---

## Notes / known constraints

- **No dataset / no QuickSight visuals** are used; all data comes from the four
  connector actions.
- **Read-only:** the connector exposes only GET actions
  (`x-amzn-operation-type: read`).
- If the connector import rejects the array response fields (`items`, `stages`,
  `history`), that is the documented OpenAPI array-schema limitation — see
  `CONNECTOR_ROUTE_CONTRACT.md` for the fallback options (JSON-string page,
  numbered fields, or REST connector type).
- The DevOps Agent chat drawer (`dashboard/src/ChatDrawer.jsx`) is intentionally
  **out of scope** for this read-only v1; add it later via a POST connector
  action or a Quick embedded-chat experience.

---

*Generated for stack `{{STACK_NAME}}` in `{{REGION}}` (account `{{ACCOUNT_ID}}`).*
