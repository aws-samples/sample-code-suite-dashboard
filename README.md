# aws-code-observability-dashboard

> [!WARNING]
> **This is sample code, not production-ready software.** It is provided as-is
> for demonstration and learning purposes. Before using any of it in a
> production environment you should review and harden the security posture
> (IAM scoping, encryption keys, logging, network isolation), add automated
> tests, plan for scale and cost, and validate that it meets your
> organization's operational and compliance requirements. No warranty is
> made regarding fitness for a particular purpose. See [LICENSE](LICENSE).

A cross-account observability dashboard for AWS CodePipeline + CodeBuild.
Captures every pipeline execution and build event into a central data lake,
enriches it with per-stage detail, exposes it through an IAM-authorized HTTP
API, and renders it locally with a React UI.

The dashboard also embeds an **AWS DevOps Agent** chat, so users can ask
natural-language questions about a specific pipeline ("why is this
failing?", "which stage is the bottleneck?") and get answers backed by
the agent's live investigation of AWS resources.

The infrastructure is deployed with **CloudFormation** (`cloudformation/`) —
three self-contained stacks (central backend, cross-account reader, and
optional sample pipelines) driven through the Makefile.

## Architecture

![High-level overview of the AWS Code Suite observability system: pipeline and build events from member accounts flow into ingestion, where a historical-forensics path (Firehose to an S3 data lake cataloged by Glue and queried by Athena) and a real-time path (an enrichment Lambda writing an enriched prefix) feed a stats Lambda behind an HTTP API, served to an app in Amazon Quick as the primary frontend and an optional React dashboard.](docs/diagrams/overview.png)

A more detailed view of the deployed CloudFormation stack:

![Architecture of the AWS Code Suite observability dashboard: CodePipeline and CodeBuild events flow through EventBridge to Firehose and an enrichment Lambda into an S3 data lake cataloged by Glue and queried by Athena; a stats Lambda serves an IAM-authorized HTTP API consumed by the local React dashboard, with cross-account reader roles and a DevOps Agent chat path.](docs/diagrams/architecture.png)

Diagrams are generated with the [`diagrams`](https://diagrams.mingrammer.com/)
library; see [`docs/diagrams/`](docs/diagrams/) for the source scripts and how to
regenerate them. The text version below is kept as a quick reference.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Central account                                                          │
│                                                                          │
│   CodePipeline / CodeBuild events                                        │
│        │                                                                 │
│        ▼                                                                 │
│   EventBridge ──► Firehose ──► S3 data lake ──► Glue + Athena            │
│        │                                                                 │
│        └────────► Enrichment Lambda ──► enriched/ prefix in data lake    │
│                                                                          │
│   Stats Lambda ◄── HTTP API (AWS_IAM auth) ◄── Vite dev server (SigV4)   │
│        │                                                                 │
│        └── sts:AssumeRole ──► PipelineDashboardReader role               │
│                                  in each tracked account                 │
│                                                                          │
│   Chat feature:                                                          │
│     POST /chat  ─►  DynamoDB (chat state)                                │
│                  ─►  Chat Worker Lambda ─► AWS DevOps Agent AgentSpace   │
│     GET  /chat/{chatId}  ─►  DynamoDB (poll for answer)                  │
└──────────────────────────────────────────────────────────────────────────┘
```

The dashboard UI runs locally on `http://localhost:5173`. The Vite dev server
proxies `/api/*` to the HTTP API and signs every request with SigV4 using the
developer's local AWS credentials — the browser never sees AWS credentials and
the API never accepts unsigned requests.

### Alternative frontend: an app in Amazon Quick

The same backend can also drive a dashboard built as an **app in Amazon Quick**,
reached through an OAuth2-authorized OpenAPI **connector** instead of the local
Vite + SigV4 proxy (the Quick sandbox cannot sign SigV4 requests). This path
adds a Cognito-backed JWT authorizer and a set of flat, paginated
`/connector/*` routes alongside the existing IAM routes.

![Connector-only architecture: an app in Amazon Quick calls an OpenAPI action connector authenticated with OAuth2 client credentials, which reaches a JWT-authorized HTTP API and the stats Lambda over the same data lake and ingestion backend, with no QuickSight dataset.](docs/diagrams/connector.png)

See [`cloudformation/dashboard-backend/QUICK_APP_QUICKSTART.md`](cloudformation/dashboard-backend/QUICK_APP_QUICKSTART.md)
for the end-to-end deploy-and-build walkthrough.

## Repo layout

```
.
├── cloudformation/             # CloudFormation IaC (3 self-contained stacks)
│   ├── dashboard-backend/      # Lambdas, API GW, S3 + Glue + Athena, Firehose, EventBridge
│   ├── cross-account-reader/   # IAM role deployed into each target account
│   └── sample-pipelines/       # 3 demo pipelines (Python / Node / static) — OPTIONAL, for testing
├── dashboard/                  # React + Vite + Tailwind UI (local-only)
├── scripts/                    # Python helpers (e.g. SigV4 API caller)
└── Makefile                    # single entrypoint — see `make help`
```

## Prerequisites

- AWS CLI v2, logged in to the central account
- Node 20+ and npm (for the dashboard UI)
- Python 3.10+ (for `scripts/awscall.py` and CodeCommit's git remote helper)
- `git-remote-codecommit` for seeding sample pipelines:
  `pip install --user git-remote-codecommit`
- An IAM identity (user, role, or SSO permission set) to run the dashboard as.
  The Vite dev server picks it up from the standard AWS credential chain (env
  vars, `~/.aws/credentials`, SSO) and uses it to SigV4-sign every API call.
  It needs:
  - `execute-api:Invoke` on
    `arn:aws:execute-api:<region>:<account>:<api-id>/*/*` — granted by the
    managed policy emitted as the `ApiInvokePolicyArn` stack output. The
    Quick-start steps attach this for you.
  - The usual AWS sign-in permissions for the credential source you're using
    (`sts:AssumeRoleWithSSO` for SSO, `sts:AssumeRole` for assumed roles,
    long-lived access keys for an IAM user). These are governed by your
    SSO/role config, not by this project.

  Minimum standalone policy (equivalent to attaching `ApiInvokePolicyArn`):

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:<region>:<account>:<api-id>/*/*"
    }]
  }
  ```

## Quick start

```bash
# 0. One-time: create a packaging bucket for Lambda zips
export CFN_PKG_BUCKET=cfn-pkg-$(aws sts get-caller-identity --query Account --output text)-us-east-1
aws s3 mb "s3://$CFN_PKG_BUCKET"

# 1. Deploy the central backend
make deploy-cfn-dashboard

# 2. (Optional) Deploy + seed the demo pipelines so the dashboard has data.
#    Skip this if you already have real CodePipeline/CodeBuild activity, or
#    plan to onboard tracked accounts and use their pipelines instead.
make deploy-cfn-sample-pipelines
make seed-cfn-samples

# 3. Attach the API invoke policy (output from step 1)
aws iam attach-user-policy \
  --user-name $(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}') \
  --policy-arn $(aws cloudformation describe-stacks \
    --stack-name pipeline-dashboard \
    --query 'Stacks[0].Outputs[?OutputKey==`ApiInvokePolicyArn`].OutputValue' \
    --output text)

# 4. Run the dashboard locally
make run-dashboard
```

See `cloudformation/README.md` for per-stack deploy details and the
parameters each stack accepts.

## Running the dashboard

```bash
make install-dashboard   # first time only — npm install
make run-dashboard       # http://localhost:5173
```

`dashboard/.env` holds `VITE_API_URL`. It must point at the API you deployed
(the `StatsApiUrl` output from `make deploy-cfn-dashboard`). The Vite dev
server signs every
`/api/*` request with SigV4 using your local AWS credential chain — no
secrets ever live in the browser.

## Multi-account / Organizations

To observe pipelines across other AWS accounts:

```bash
# Per-account onboarding
make track-account PROFILE=<other-aws-profile> ALIAS=<short-label>

# Or auto-discover everything in your AWS Organization
make enable-org-tracking ROOT_ID=r-xxxx
```

The first form deploys the read-only `PipelineDashboardReader` role into the
target account and prints the entry to add to the central stack's
`TrackedAccounts` parameter. The second form uses CloudFormation StackSets to
push the role to every account in the org and lets the stats Lambda enumerate
them at runtime.

## DevOps Agent chat

The dashboard ships with a chat drawer (bottom-right of the UI) that talks
to [AWS DevOps Agent](https://aws.amazon.com/devops-agent/) via a
dedicated worker Lambda. Users pick a pipeline, ask a question, and the
agent investigates the live AWS environment to answer — for example:

- "Why is this pipeline failing?"
- "Which stage is the bottleneck?"
- "Look at the latest CodeBuild logs and summarize the error."
- "What changed since the last successful run?"

### How it works

Because DevOps Agent investigations can take longer than API Gateway's
30-second integration timeout, the chat uses an async request-response
pattern:

```
POST /chat
  ├─ persist { chatId, status: "processing" } to DynamoDB
  ├─ invoke chat-worker Lambda (async)
  └─ return { chatId } immediately

chat-worker Lambda
  ├─ devops-agent:CreateChat   (against the AgentSpace)
  ├─ devops-agent:SendMessage  (streaming EventStream)
  ├─ accumulate text deltas until responseCompleted
  └─ UpdateItem { status: "succeeded", answer } in DynamoDB

GET /chat/{chatId}
  └─ return current DynamoDB state (the UI polls every 2s)
```

The chat state table (`pipeline-dashboard-chat`) has a 24-hour TTL, so
records auto-delete.

### What the chat backend needs

> [!NOTE]
> The chat drawer is wired into the dashboard UI, but its backend
> (AgentSpace + chat-worker Lambda + chat state table + the `POST /chat`
> and `GET /chat/{chatId}` routes) is **not** part of the CloudFormation
> stacks in this repo. The CloudFormation `dashboard-backend` stack deploys
> the ingestion/stats backend only. To use the chat feature you need to
> provision the following components yourself and point the UI at an API
> that serves the `/chat` routes.

The chat backend is made up of:

- An **AWS DevOps Agent AgentSpace**, associated with the AWS account so the
  agent can investigate local CodePipeline / CodeBuild resources.
- Two IAM roles trusted by `aidevops.amazonaws.com`: a read-only monitoring
  role (`AIDevOpsAgentAccessPolicy`) and an operator app role
  (`AIDevOpsOperatorAppAccessPolicy`).
- A DynamoDB table with a 24-hour TTL (`pipeline-dashboard-chat`) for chat
  state.
- A chat-worker Lambda (`pipeline-dashboard-chat-worker`) whose IAM is scoped
  to `aidevops:CreateChat` + `aidevops:SendMessage` on the AgentSpace ARN
  only.
- Two routes on the HTTP API: `POST /chat` and `GET /chat/{chatId}`, both
  `AWS_IAM`-authorized.

### Prerequisites

- **AWS DevOps Agent must be enabled** in the deployment account and
  region. It's a managed service — enable it once via the AWS console.
- The deploying IAM identity needs `devops-agent:CreateAgentSpace` and
  `iam:PassRole`.
- Available regions (at time of writing): `us-east-1`, `us-west-2`,
  `ap-southeast-2`, `ap-northeast-1`, `eu-west-1`, `eu-central-1`.

### Cost

DevOps Agent is billed per investigation and is not free. Bounds on the
demo:

- The chat Lambda's IAM is scoped to a single AgentSpace ARN.
- The worker Lambda has a 5-minute timeout.
- Chat records TTL out after 24 hours.

Estimate cost with the [AWS DevOps Agent pricing
page](https://aws.amazon.com/devops-agent/pricing/) before enabling in a
production account.

## Security model

- **API:** every route on the HTTP API has `AuthorizationType: AWS_IAM`.
  Unsigned requests get HTTP 403. To call the API a principal must have
  `execute-api:Invoke` on the route ARN — the deploy outputs a managed policy
  (`ApiInvokePolicyArn`) you can attach to whoever needs access. See
  [Prerequisites](#prerequisites) for the exact permissions needed by the
  IAM identity that runs the dashboard locally.
- **S3 buckets:** all four public-access-block flags on. Bucket policies
  deny non-TLS access. No public website hosting.
- **Cross-account:** the reader role's trust policy is locked to the central
  stats Lambda role ARN.
- **Lambdas:** AWS-managed encryption on env vars + CloudWatch logs.
  No Function URLs. Permissions scoped to specific resource ARNs where
  AWS supports it.
- **DevOps Agent:** the chat-worker Lambda's IAM allows only
  `aidevops:CreateChat` and `aidevops:SendMessage`, scoped to this
  project's AgentSpace ARN — it cannot start investigations against any
  other AgentSpace. The AgentSpace's own monitoring role
  (`AIDevOpsAgentAccessPolicy`) is read-only. The chat state table is
  encrypted at rest and auto-expires records after 24 hours.

## Common operations

```bash
make help                       # full list of targets
make plan-cfn-dashboard         # cfn change set, no apply
make deploy-cfn-dashboard       # deploy the central backend stack
make destroy-cfn-dashboard      # tear it all down
make list-tracked-accounts      # GET /accounts via SigV4 + jq
```

## Conventions

Highlights of the project style guide:

- Always go through the Makefile — don't invent new `cloudformation deploy`
  invocations.
- API calls live in `dashboard/src/pipelineService.js`; keep `App.jsx`
  free of `fetch`.
- Never hardcode `VITE_API_URL` — it comes from the `.env` at build time.
- Never commit `.env` or secrets — `.env` is already gitignored.

## Security

See [SECURITY](SECURITY.md) for how to report security issues.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
