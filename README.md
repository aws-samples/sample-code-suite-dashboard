# aws-code-observability-dashboard

A cross-account observability dashboard for AWS CodePipeline + CodeBuild.
Captures every pipeline execution and build event into a central data lake,
enriches it with per-stage detail, exposes it through an IAM-authorized HTTP
API, and renders it locally with a React UI.

The infrastructure can be deployed two ways — pick one:

- **Terraform** (`terraform/`) — the canonical source of truth.
- **CloudFormation** (`cloudformation/`) — a self-contained mirror for teams
  that standardize on CFN/StackSets.

Both deploy paths produce the same architecture and can be used independently.

## Architecture

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
└──────────────────────────────────────────────────────────────────────────┘
```

The dashboard UI runs locally on `http://localhost:5173`. The Vite dev server
proxies `/api/*` to the HTTP API and signs every request with SigV4 using the
developer's local AWS credentials — the browser never sees AWS credentials and
the API never accepts unsigned requests.

## Repo layout

```
.
├── terraform/                  # canonical IaC
│   ├── dashboard-backend/      # Lambdas, API GW, S3 + Glue + Athena, Firehose, EventBridge
│   ├── cross-account-reader/   # IAM role deployed into each target account
│   ├── sample-pipelines/       # 3 demo pipelines (Python / Node / static)
│   └── modules/                # shared TF modules
├── cloudformation/             # CFN mirror of the same 3 stacks (self-contained)
├── dashboard/                  # React + Vite + Tailwind UI (local-only)
├── scripts/                    # Python helpers (e.g. SigV4 API caller)
└── Makefile                    # single entrypoint — see `make help`
```

## Prerequisites

- AWS CLI v2, logged in to the central account
- Terraform ≥ 1.5 (Terraform path) **or** just the AWS CLI (CloudFormation path)
- Node 20+ and npm (for the dashboard UI)
- Python 3.10+ (for `scripts/awscall.py` and CodeCommit's git remote helper)
- `git-remote-codecommit` for seeding sample pipelines:
  `pip install --user git-remote-codecommit`

## Quick start — Terraform path

```bash
# 1. Deploy the central backend (Lambdas, API, data lake, etc.)
make deploy-dashboard

# 2. Deploy 3 demo pipelines so the dashboard has data
make deploy-sample-pipelines

# 3. Attach the API invoke policy to the IAM identity you'll run the UI as
aws iam attach-user-policy \
  --user-name $(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}') \
  --policy-arn "$(terraform -chdir=terraform/dashboard-backend output -raw api_invoke_policy_arn)"

# 4. Run the dashboard locally
make run-dashboard       # http://localhost:5173
```

## Quick start — CloudFormation path

```bash
# 0. One-time: create a packaging bucket for Lambda zips
export CFN_PKG_BUCKET=cfn-pkg-$(aws sts get-caller-identity --query Account --output text)-us-east-1
aws s3 mb "s3://$CFN_PKG_BUCKET"

# 1. Deploy the central backend
make deploy-cfn-dashboard

# 2. Deploy + seed the demo pipelines
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

See `cloudformation/README.md` for differences from the Terraform path
(notably `seed.tf` → manual seed step, no `for_each` over samples).

## Running the dashboard

```bash
make install-dashboard   # first time only — npm install
make run-dashboard       # http://localhost:5173
```

`dashboard/.env` holds `VITE_API_URL`. It must point at whichever API you
deployed (`make deploy-dashboard` Terraform output, or
`make deploy-cfn-dashboard` CFN output). The Vite dev server signs every
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
target account and adds the account to `tracked_accounts` in the central
stack. The second form uses CloudFormation StackSets to push the role to every
account in the org and lets the stats Lambda enumerate them at runtime.

## Security model

- **API:** every route on the HTTP API has `AuthorizationType: AWS_IAM`.
  Unsigned requests get HTTP 403. To call the API a principal must have
  `execute-api:Invoke` on the route ARN — the deploy outputs a managed policy
  (`api_invoke_policy_arn`) you can attach to whoever needs access.
- **S3 buckets:** all four public-access-block flags on. Bucket policies
  deny non-TLS access. No public website hosting.
- **Cross-account:** the reader role's trust policy is locked to the central
  stats Lambda role ARN. Organizations mode further constrains AssumeRole
  with `aws:ResourceOrgID` (Terraform path only — see CFN README for the
  workaround).
- **Lambdas:** AWS-managed encryption on env vars + CloudWatch logs.
  No Function URLs. Permissions scoped to specific resource ARNs where
  AWS supports it.

## Common operations

```bash
make help                       # full list of targets
make plan-dashboard             # terraform plan
make plan-cfn-dashboard         # cfn change set, no apply
make sync-cfn-from-tf           # rsync lambda/ + sample-apps/ from TF to CFN
make destroy-dashboard          # tear it all down
make list-tracked-accounts      # GET /accounts via SigV4 + jq
```

## Conventions

The project conventions doc (`.kiro/steering/project-conventions.md`, local-
only) is the binding style guide. Highlights:

- Always go through the Makefile — don't invent new `terraform apply` or
  `cloudformation deploy` invocations.
- `terraform fmt` before committing TF changes.
- API calls live in `dashboard/src/pipelineService.js`; keep `App.jsx`
  free of `fetch`.
- Never hardcode `VITE_API_URL` — it comes from the `.env` at build time.
- Never commit `.env`, `*.tfvars` with secrets, or `terraform.tfstate*` —
  already gitignored.
