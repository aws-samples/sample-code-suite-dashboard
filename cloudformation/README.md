# CloudFormation deployment

The infrastructure for the AWS Code Suite observability dashboard, as three
self-contained CloudFormation stacks. Deploy them with the AWS CLI (directly
or through the repo's Makefile) or one-shot from the AWS console.

The Lambda source code and sample app sources live alongside the templates:

```
cloudformation/dashboard-backend/lambda/{enrichment,stats}/index.py
cloudformation/sample-pipelines/sample-apps/{python-api,node-api,static-site}/
```

## Layout

| Folder | What it deploys |
|---|---|
| `cross-account-reader/` | Read-only IAM role in a target account. Deploy once per tracked account. |
| `dashboard-backend/` | Central stack: Lambdas, API Gateway, S3 data lake, Firehose, EventBridge, Glue, Athena, alarms, optional Organizations StackSet. |
| `sample-pipelines/` | Three demo CodePipelines (Python/Node/static) so the dashboard has data. |

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

**Note:** this stack does **not** auto-seed the CodeCommit repos with starter
source. After deploy, run the seed helper:

```bash
make seed-cfn-samples
```

This pushes `sample-apps/<dir>/` into each repo's `main` branch using your
local AWS credentials.

## Notes and limitations

| Area | Behavior | Why |
|---|---|---|
| Modules | Resources inlined per stack | CFN has no first-class modules. Nested stacks add bootstrap overhead. |
| Sample pipelines | Hard-coded 3 samples | The sample list is fixed; CFN macros aren't ergonomic. |
| Seeding sample repos | Manual step (`make seed-cfn-samples`) | A CFN custom resource would need a deploy-time Lambda just to seed. Not worth it. |
| Synthetic account generation | `SyntheticAccountCount` parameter (default 0) | Demo-only feature; set 0 in production. |
| Organizations StackSet | Controlled by the `OrgEnabled` parameter | Pushes the reader role to every account in the org. |
