Build an app called "AWS CodeSuite Dashboard". It must look and behave like an
AWS Management Console service page in the AWS Cloudscape design system,
light mode. Follow every detail below exactly. Use only my connector actions
`getAccounts`, `getPipelines` and `getPipeline` for data. Do not mock, stub,
sample or hardcode any data, and do not use `getStats`.

**1. Data**

On load and then every 30 seconds:
- Call `getAccounts` and keep every item in `items` (`id`, `alias`,
  `region`). The 12-digit AWS account number is the last 12 digits of `id`.
- Call `getPipelines` with `pageSize` 100. If `nextToken` is not empty, call
  it again with that `nextToken` until it is empty. Each item is a pipeline
  summary: `accountId`, `accountAlias`, `region`, `name`, `repository`,
  `branch`, `triggerType`, `status`, `version`, `lastRunStart` (epoch ms),
  `durationMs`, `logsUrl`.
- For every pipeline, call `getPipeline` with its `accountId` and `name` (as
  `pipelineName`) and merge the result into the summary. It adds `stages`
  (each `name`, `status`, `url`) and `history` (each `status`, `durationMs`,
  `startTime` epoch ms).
- If a refresh fails, quietly keep showing the last good data.
- Status values are `Succeeded`, `InProgress`, `Failed`, `Stopped`. Treat a
  missing status as `Stopped`.

Everything on the page reflects only the accounts selected in the account
dropdown (all accounts are selected at first).

**2. Page and fonts**

- The page background is white `#ffffff`. Body text `#16191f`, headings
  `#000716`, secondary text `#5f6b7a`, muted text `#7d8998`, links and
  active controls `#0972d3` (hover `#033160`).
- Font: Inter for text. JetBrains Mono (or another monospace font) with
  tabular numerals for versions, durations, times, account IDs, Regions,
  repository names and counts.
- "Container" below means: white background, 16px rounded corners, no
  border, and this shadow: `0 1px 1px 0 rgba(0,28,36,0.3), 1px 1px 1px 0
  rgba(0,28,36,0.15), -1px 1px 1px 0 rgba(0,28,36,0.15)`.
- "Blue button" means: 32px tall, pill-shaped (20px radius), white
  background, 2px `#0972d3` border, bold 14px `#0972d3` text, 16px
  horizontal padding; on hover the background becomes `#f2f8fd` and the
  border and text become `#033160`.

**3. Top navigation bar**

A full-width bar at the very top, 40px tall, background `#232f3e`, 16px
left padding.
- Left: an "aws" wordmark: the lowercase letters "aws" in bold white Arial,
  17px, tight letter spacing, with an orange `#ff9900` curved smile under the
  letters that ends in a small arrowhead on the right. Then a 1px × 20px
  vertical divider in `#414d5c`. Then "AWS CodeSuite Dashboard" in bold white
  14px, with 12px padding on the left.
- Right: the Region in view: a white globe icon followed by the Region in
  white 14px, for example "us-east-1". If the selected accounts are in
  several Regions, show "N regions" and list them in a tooltip. Then another
  `#414d5c` divider. Then the account in view: the 12-digit account number in
  white followed by the alias in light grey `#d1d5db` in parentheses, for
  example "111122223333 (aws)". With several accounts selected show "N
  accounts"; with none, "No account selected". Hovering shows a tooltip
  listing "alias · account number · Region" for each selected account. Both
  items turn `#ff9900` on hover.

**4. Breadcrumbs and page header**

The content area has 28px left and right padding.
- Breadcrumbs, 16px below the top bar, 14px: "AWS CodeSuite Dashboard" in
  `#0972d3`, a small grey right-chevron, then "Pipelines" in `#5f6b7a`.
- 12px below, the page header row. On the left:
  - The title "Pipelines" in 24px bold `#000716`, followed by the number of
    pipelines in view in normal weight `#5f6b7a` in parentheses, for example
    "Pipelines (6)". After it, the word "Info" in bold 14px `#0972d3`.
  - Under the title, 14px `#5f6b7a`: "CodePipeline and CodeBuild activity
    across your tracked accounts." followed, after 8px, by 12.5px monospace
    "Last refreshed 02:33:14 PM · next in 23s". The countdown ticks every
    second from 30 to 0, then the data reloads.
- On the right of the header row, aligned to the bottom, 8px apart:
  - A round refresh button: 32px circle, white, 2px `#0972d3` border, a
    `#0972d3` circular-arrow icon centered. Clicking it reloads now and
    resets the countdown. While loading, the icon spins and the button turns
    grey (`#9ba7b6`) and can't be clicked. Tooltip: "Refresh now
    (auto-refresh in Ns)".
  - The account dropdown, a blue button with a small down caret. Its label
    is "All accounts (N)" when all are selected, "ALIAS only" (alias in
    capitals) when exactly one is selected, "K of N" when some are
    selected, and "0 of N" when none are.

**5. Account dropdown panel**

Clicking the account button opens a panel under it, aligned right, 340px
wide, white, 2px `#9ba7b6` border, 8px rounded corners, soft drop shadow.
Clicking outside closes it.
- At the top, a search box (32px tall, 2px border) with a magnifier icon and
  the placeholder "Search N accounts…". It has focus when the panel opens and
  filters accounts by alias, account number or Region. An "x" clears it.
- Under the search, a 11.5px line: "K selected" (and " · M matches" while
  searching) on the left; on the right, blue links "Select all" (or "Select
  matching" while searching) and grey "Clear", separated by a dot.
- Then a scrollable list (up to 420px tall). Each row: a 16px square
  checkbox (blue `#0972d3` filled with a white check when selected), then
  the alias in 12.5px (bold dark for "aws", orange `#b15c00` for aliases
  starting with "prod", blue `#0073bb` otherwise), " · ", and the 12-digit
  number in grey monospace; on a second line, the Region in 10.5px grey
  monospace. Clicking a row toggles it. On hover the row turns `#f1f8fd` and
  a small blue "Only" link appears on the right, which selects just that
  account. If nothing matches: "No accounts match "query"".

**6. Stat tiles**

16px below the header, a row of four containers, 12px apart (four across on
wide screens, two across on narrow ones). Each tile has 20px horizontal and
16px vertical padding: a bold 14px `#000716` label, then 4px below a 32px
light-weight number, then 6px below a 12px `#5f6b7a` subtitle. Compute from
the merged pipelines in view; "last 24h" means `startTime` within the past
24 hours.
1. "Total pipelines": the number of pipelines. Subtitle "across N
   account(s)" using the number of selected accounts. Number in `#16191f`.
2. "Currently running": pipelines whose status is `InProgress`. Number blue
   `#0073bb` when above 0, else `#16191f`. Subtitle "live executions" when
   above 0, else "no active executions".
3. "Failed (last 24h)": the number of `history` runs with status `Failed` in
   the last 24h, plus 1 for each pipeline whose current status is `Failed`
   and whose `lastRunStart` is in the last 24h. Number red `#d91515` when
   above 0. Subtitle "click to view failed pipelines" when above 0, else "all
   clear".
4. "Success rate (24h)": succeeded ÷ all `history` runs in the last 24h,
   rounded, shown with a "%" sign; 100% when there are no runs. Number green
   `#037f0c` at 90% or more, blue `#0073bb` from 70% to 89%, red `#d91515`
   below 70%. Subtitle "N runs in window".

The tiles are buttons. Clicking one selects a filter tab, and clicking it
again goes back to "All": Total → All, Currently running → Running, Failed
→ Failed 24h, Success rate → Healthy. The tile matching the active tab has
a 2px `#0972d3` ring and a `#f2f8fd` background; other tiles turn
`#fafafa` on hover.

**7. Filter row**

20px below the tiles and 12px above the cards, one row:
- A segmented control: one connected box with a 2px `#7d8998` border and
  8px rounded corners, divided into tabs by 1px `#e9ebed` lines. Each tab is
  32px tall with 12px padding: the label in 13px, then its count in 11.5px
  monospace. Tabs: "All" (all pipelines), "Running" (status `InProgress`),
  "Failed" (status `Failed`), "Failed 24h" (status `Failed`, or any `Failed`
  run in `history` in the last 24h), "Healthy" (status `Succeeded`),
  "Stopped" (status `Stopped`). The active tab is filled `#0972d3` with bold
  white text and a light count; inactive tabs are `#5f6b7a` with `#7d8998`
  counts and turn `#f7f8f8` on hover.
- 12px to the right, a 280px search box: 32px tall, 8px rounded corners,
  2px `#7d8998` border (blue `#0972d3` with a soft blue glow when focused),
  a grey magnifier icon inside on the left, 14px text, and the italic grey
  placeholder "Search pipelines, repos, versions". It matches pipeline name,
  repository and version, ignoring case.
- On the far right, 12.5px monospace `#5f6b7a`: "showing X / Y", with X in
  `#16191f`.

**8. Pipeline cards**

A grid with 12px gaps: three columns on wide screens, two on medium, one on
narrow. One card per pipeline that passes the tab and search filters. Each
card is a container whose shadow grows on hover (`0 4px 20px 1px
rgba(0,7,22,0.10)`). It has four parts: a header, then a 1px `#e9ebed`
line, then the stages and details with no line between them, then a 1px
`#e9ebed` line and the footer.

*Header* (16px side padding, 14px top, 12px bottom):
- First line: the pipeline `name` as a 15px bold `#0972d3` link (underline
  on hover) to `logsUrl`, opening in a new tab, cut off with an ellipsis if
  too long. On the far right of the same line, the status in 13px in the
  status color with a 14px circle icon: Succeeded `#037f0c` with a check
  mark, Failed `#d91515` with an "x", "In progress" `#0073bb` with a dot and
  a pulsing ring, Stopped `#5f6b7a` with a minus.
- Second line, 4px below, small chips 8px apart. Every chip has 10px
  rounded corners, a 1px border, 6px horizontal padding and 11px text:
  - Framework chip, guessed from the pipeline name and repository (ignore
    case): "python", "django", "flask" or "fastapi" → "Python" `#16a34a`;
    "java", "spring", "maven", "gradle" or "kotlin" → "Java" `#e76f00`;
    "dotnet", ".net", "csharp" or "aspnet" → ".NET" `#7c3aed`; "typescript",
    "next", "nest", "react", "vue", "angular", "node", "frontend", "web" or
    "ui" → "TypeScript" `#db2777`; "go" or "golang" → "Go" `#0d9488`;
    "rust" or "cargo" → "Rust" `#b45309`; "ruby" or "rails" → "Ruby"
    `#cc342d`. Text in that color, background the color at 10% opacity,
    border at 40% opacity, with a 9px dot of the color before the label. No
    framework chip when nothing matches.
  - Account chip: the alias in capitals, medium weight, then the 12-digit
    account number in monospace at 70% opacity, for example "AWS
    111122223333". Blue: text `#0073bb`, background `#f1f8fd`, border
    `#cee0f5`. If the alias is "prod", orange instead: text `#b15c00`,
    background `#fef6f0`, border `#f0c096`.
  - Region chip: a 10px globe icon and the `region` in monospace. Text
    `#5f6b7a`, background `#f2f3f3`, border `#d1d5db`.
  - The `repository` as plain 12px `#5f6b7a` monospace text.
  - Branch chip: a small branch icon and the `branch` in monospace, at most
    220px wide with an ellipsis. Branches starting "feature/" are purple
    (text `#5b21b6`, background `#f5f0fb`, border `#dcd0ee`); starting
    "bugfix/" are orange (text `#b15c00`, background `#fef6f0`, border
    `#f0c096`); everything else is grey (text `#5f6b7a`, background
    `#f2f3f3`, border `#d1d5db`).

*Stages* (16px side padding, 12px top and bottom):
- A line with "STAGES" on the left in 11px semibold uppercase `#7d8998`
  with wide letter spacing, and the trigger on the right in 11px monospace
  `#5f6b7a` with a small icon: `Manual` → hand icon "Manual run", `GitTag` →
  tag icon "Git tag push", `BranchMerge` → branch icon "Branch merge",
  `Schedule` → clock icon "Scheduled".
- 8px below, one bar per entry in `stages`, side by side and equally wide,
  6px apart. Each bar is 4px tall with rounded ends, on a `#eaedf0` track,
  fully filled with the stage's status color (`#037f0c`, `#0073bb`,
  `#d91515` or `#7d8998`) if the stage has a status, or empty if not. An
  in-progress bar has a light shimmer sliding across it.
- 6px under each bar, in 11px: the stage number (1, 2, 3…) in `#7d8998`
  monospace, then the stage name in the stage's color (green, medium-weight
  blue, red, or `#5f6b7a` when it hasn't run). If the stage has a `url`, the name
  links to it in a new tab and underlines on hover.

*Details* (16px side padding, 12px bottom): three equal columns, "VERSION",
"LAST RUN" and "DURATION". Each has a 10.5px semibold uppercase `#7d8998`
label with wide letter spacing over a 12.5px monospace `#16191f` value:
`version`; the time since `lastRunStart` ("12s ago", "15 min ago", "3h ago",
"2d ago"); and `durationMs` as "45s" or "1m 53s" (seconds always two
digits).

*Footer* (16px side padding, 10px top and bottom, white):
- Left: a small bar chart, 104px wide and 28px tall, one bar per `history`
  run in order, 2px apart with slightly rounded tops. Bar height is the run's
  `durationMs` ÷ 10 minutes, kept between 30% and 100% of the chart height
  (1 minute if missing). Color: `#037f0c` for Succeeded, `#d91515` for
  Failed, `#9aa7b5` otherwise. Hovering a bar shows a small white tooltip
  with its status.
- 10px after the chart, 11.5px monospace: the number of succeeded runs in
  green `#037f0c`, then "/" and the total number of runs in `#7d8998`, then
  " · " and the success percentage in `#5f6b7a`, for example "2/3 · 67%".
- Right: a 12.5px `#0972d3` link "View logs" followed by a small
  external-link icon, to `logsUrl` in a new tab.

**9. Empty, loading and footer states**

- While the first load is running, show six grey pulsing placeholder
  containers, 176px tall, in the card grid.
- If filters hide every pipeline, show one container with 80px top and
  bottom padding and centered 14px `#5f6b7a` text: "No pipelines match the
  current filter."
- Under the grid, 32px below, 11.5px monospace `#7d8998`: "Auto-refresh
  every 30s · live data via dashboard API". Leave 40px of space at the
  bottom of the page.

Don't add anything that isn't described here: no extra charts, sidebars,
navigation, sample data or explanatory text.
