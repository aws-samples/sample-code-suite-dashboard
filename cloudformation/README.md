# CloudFormation deployment

CloudFormation mirror of the Terraform stacks under `../terraform/`. Pick this
path if you can't use Terraform locally (e.g. enterprise environments that
standardize on CFN/StackSets, or one-shot deploys from the AWS console).

This folder is **self-contained** — it can be deployed (or deleted) without
needing `../terraform/` present. The Lambda source code and sample app
sources are duplicated here:

```
cloudformation/dashboard-backend/lambda/{enrichment,stats}/index.py
cloudformation/sample-pipelines/sample-apps/{python-api,node-api,static-site}/
```

> Terraform is treated as the canonical source for the shared application
> code. After editing anything under `terraform/{dashboard-backend/lambda,
> sample-pipelines/sample-apps}/`, run `make sync-cfn-from-tf` to mirror
> the change into this folder before re-deploying the CFN stack.

## Layout

| Folder | Terraform equivalent | What it deploys |
|---|---|---|
| `cross-account-reader/` | `terraform/cross-account-reader/` | Read-only IAM role in a target account. Deploy once per tracked account. |
| `dashboard-backend/` | `terraform/dashboard-backend/` | Central stack: Lambdas, API Gateway, S3 data lake, Firehose, EventBridge, Glue, Athena, alarms, optional Organizations StackSet. |
| `sample-pipelines/` | `terraform/sample-pipelines/` | Three demo CodePipelines (Python/Node/static) so the dashboard has data. |

## Prerequisites

- AWS CLI v2 authenticated to the target account.
- An S3 bucket in the deploy region for CFN packaging (Lambda zips). Create
  one once per region:
  ```bash
  aws s3 mb s3://cfn-pkg-$(aws sts get-caller-identity --query Account --output text)-us-east-1
  ```
- jq (for Makefile helpers).

## Deploy

Set a packaging bucket once:

```bash
export CFN_PKG_BUCKET=cfn-pkg-$(aws sts get-caller-identity --query Account --output text)-us-east-1
```

Then either use the Makefile (`make deploy-cfn-dashboard`, etc.) or run the
commands directly — see each stack's section below.

### 1. Dashboard backend (central account)

```bash
cd cloudformation/dashboard-backend

aws cloudformation package \
  --template-file template.yaml \
  --s3-bucket "$CFN_PKG_BUCKET" \
  --output-template-file .packaged.yaml

aws cloudformation deploy \
  --stack-name pipeline-dashboard \
  --template-file .packaged.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName=pipeline-dashboard \
    CorsAllowOrigin=http://localhost:5173 \
    OrgEnabled=false
```

Outputs of note:

- `StatsApiUrl` — base URL of the IAM-authorized HTTP API.
- `StatsLambdaRoleArn` — paste into `CentralLambdaRoleArn` when deploying
  `cross-account-reader/` into target accounts.
- `ApiInvokePolicyArn` — managed policy granting `execute-api:Invoke`. Attach
  to any IAM principal that needs to call the API.

### 2. Cross-account reader (per target account)

In each target account that should be observable:

```bash
cd cloudformation/cross-account-reader

aws cloudformation deploy \
  --stack-name pipeline-dashboard-reader \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    CentralLambdaRoleArn=arn:aws:iam::<central-account>:role/pipeline-dashboard-stats-lambda-role
```

### 3. Sample pipelines (central account, optional)

```bash
cd cloudformation/sample-pipelines

aws cloudformation deploy \
  --stack-name pipeline-dashboard-samples \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM
```

**Note:** unlike the Terraform stack (`seed.tf`), this CFN stack does **not**
auto-seed the CodeCommit repos with starter source. After deploy, run the
seed helper:

```bash
make seed-cfn-samples
```

This pushes `sample-apps/<dir>/` into each repo's `main` branch using your
local AWS credentials, the same way `terraform/sample-pipelines/seed.tf` does
via `local-exec`.

## Differences from the Terraform stacks

| Area | Terraform | CloudFormation | Why |
|---|---|---|---|
| Modules | 10 reusable modules under `terraform/modules/` | Inlined per stack | CFN has no first-class modules. Nested stacks add bootstrap overhead. |
| `for_each` over `samples` map | Yes | Hard-coded 3 samples | CFN macros aren't ergonomic; the sample list is fixed. |
| `seed.tf` (local-exec git push) | Runs on `terraform apply` | Manual step (`make seed-cfn-samples`) | CFN custom resources would need a deploy-time Lambda just to seed. Not worth it. |
| Synthetic account generation | `synthetic_account_count` var | Skipped | Demo-only feature; not commonly used. Add back as a parameter if needed. |
| Organizations StackSet | Always controlled by `tracked_organization.enabled` | Same — `OrgEnabled` parameter | Equivalent. |
