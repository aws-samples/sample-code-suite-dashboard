# Quickstart - deploy the dashboard as an app in Amazon Quick

End-to-end walkthrough for standing up the whole solution: the AWS backend
(CloudFormation) plus the Amazon Quick app that renders it through an OpenAPI
connector. This is the "start here" guide; the other docs go deeper:

- `CONNECTOR_DEPLOY_RUNBOOK.md` - detailed backend deploy + connector wiring.
- `connector/QUICK_APP_PROMPT.generated.md` - the phased app-build prompts
  (produced by `scripts/render_quick_app.py`).
- `CONNECTOR_ROUTE_CONTRACT.md` - the connector API design.
- `CONNECTOR_TEARDOWN.md` - full teardown.

The solution has **two parts**:

1. **Backend** - full CloudFormation lifecycle (deploy / destroy scripted).
2. **Quick app** - built in the Quick console from a prompt; deleted manually
   (Amazon Quick has no create/delete API for apps or connectors).

> Assumes your AWS CLI is already configured for your target account. You run
> the commands; substitute your own region. A Quick-supported region is
> required (e.g. us-east-1, us-west-2, eu-west-1, ap-southeast-2).

---

## Part 1 - Deploy the backend (CloudFormation)

```bash
export CFN_REGION=<your-region>
export CFN_STACK_NAME=pipeline-dashboard
export CONNECTOR_DOMAIN_PREFIX=pipeline-dashboard-$(aws sts get-caller-identity --query Account --output text)

# 1. Packaging bucket (one-time)
export CFN_PKG_BUCKET=aws-code-observability-cfn-artifacts-$(aws sts get-caller-identity --query Account --output text)-${CFN_REGION}
aws s3 mb "s3://$CFN_PKG_BUCKET" --region "$CFN_REGION"

# 2. Package + deploy the backend WITH the connector turned on.
#    Prefer the Makefile target (run from the repo root):
make deploy-cfn-connector \
  CFN_PKG_BUCKET="$CFN_PKG_BUCKET" \
  CFN_REGION="$CFN_REGION" \
  CONNECTOR_DOMAIN_PREFIX="$CONNECTOR_DOMAIN_PREFIX"
```

<details><summary>Raw CLI equivalent (if you're not using the Makefile)</summary>

```bash
cd cloudformation/dashboard-backend
aws cloudformation package \
  --template-file template.yaml --s3-bucket "$CFN_PKG_BUCKET" \
  --output-template-file .packaged.yaml --region "$CFN_REGION"
aws cloudformation deploy \
  --stack-name "$CFN_STACK_NAME" --template-file .packaged.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ConnectorAuthDomainPrefix="$CONNECTOR_DOMAIN_PREFIX" \
  --region "$CFN_REGION"
```
</details>

**(Optional) sample pipelines** so the dashboard has data to show:

```bash
aws cloudformation deploy \
  --stack-name "${CFN_STACK_NAME}-samples" \
  --template-file ../sample-pipelines/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM --region "$CFN_REGION"
make seed-cfn-samples CFN_REGION="$CFN_REGION"     # run from repo root; needs git-remote-codecommit
# The sample pipelines auto-run once on create against empty repos (Source
# fails). After seeding, kick a fresh run so they go green:
for p in sample-node-api-pipeline sample-python-api-pipeline sample-static-site-pipeline; do
  aws codepipeline start-pipeline-execution --name "$p" --region "$CFN_REGION"
done
```

> Data appears in the dashboard only after pipelines emit events and the
> enrichment Lambda processes them (EventBridge -> Firehose -> S3 -> Athena) -
> allow a few minutes.

---

## Part 2 - Render the connector artifacts

```bash
make render-quick-app CFN_REGION="$CFN_REGION"
# raw equivalent: python3 scripts/render_quick_app.py --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION"
```

Writes (gitignored, account-specific):
- `connector/openapi.generated.json` - import into Quick.
- `connector/QUICK_APP_PROMPT.generated.md` - the phased build prompts with your
  live values.

Fetch the connector client secret (needed for the connector's auth step; not
stored in the repo):

```bash
POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$CFN_REGION" \
  --query "UserPools[?Name=='${CFN_STACK_NAME}-connector'].Id | [0]" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ConnectorClientId`].OutputValue' --output text)
aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" \
  --region "$CFN_REGION" --query 'UserPoolClient.ClientSecret' --output text
```

---

## Part 3 - Create the connector in the Quick console

Connectors -> Create for your team -> **OpenAPI Specification** -> import
`connector/openapi.generated.json`. Notes from doing this for real:

- **Description** (required): allowed characters are letters, numbers, spaces,
  and `_ . , ! ? -` only. No slashes/colons/em dashes. Safe value:
  `Read-only connector for the AWS Code Suite observability dashboard.`
- **Base URL** (required): paste the `ConnectorBaseUrl` output exactly, ending
  in `/connector`, no trailing slash. A typo in the API id makes every action
  404.
- **Authentication**: Service authentication -> OAuth2 client credentials. The
  **Scope field appears on this step**, not on the spec page. Enter the token
  URL, client ID, client secret (from Part 2), and scope
  `pipeline-dashboard/read` (with the slash).
- **Publish / "Everyone in your organization?"**: this is service-to-service
  auth (all users share one credential, same data, no per-user filtering). It
  returns read-only pipeline/build metadata, so org-wide is a reasonable default
  unless your pipeline/account names are sensitive or you add actions returning
  logs/secrets. It cannot be used in Chat or Flows (expected - we use it in an
  App).
- Confirm the four actions exist and work: `getStats`, `getAccounts`,
  `getPipelines`, `getPipeline`.

**Array-schema note:** the connector responses use array fields (`items`,
`stages`, `history`). These import fine - the Quick OpenAPI array-type
restriction applies to parameters, not these response bodies. (Verified during a
real deploy.)

---

## Part 4 - Build the app (prompt-only)

Apps -> create a new app. **No file attach needed** - paste the phased prompts
from `connector/QUICK_APP_PROMPT.generated.md`, one phase at a time, verifying
each:

1. **Phase 1 - Overview**: four stat tiles from `getStats`. Verify real numbers
   (not zeros/placeholders).
2. **Phase 2 - Pipelines list**: cards from `getPipelines` with filters +
   pagination.
3. **Phase 3 - Detail**: stage stepper + run-history sparkline from
   `getPipeline`.

Tips learned live:
- Include "**use the real <action> connector action - do not mock or hardcode
  data**" in each phase; app builders otherwise tend to stub data on the first
  pass.
- If a view looks visually off, paste the relevant snippet of
  `dashboard/src/App.jsx` as a targeted follow-up for just that piece.
- The app auto-refreshes, so the Overview updates as new pipeline runs land.

When it looks right, **Publish** and choose an access level (Account-level to
share with your org's Quick users; there is no anonymous/public option for a
connector-backed app).

---

## Part 5 - Teardown

**Quick app + connector (manual - no API):**
1. App -> App settings -> Overview -> **Delete**.
2. Connectors -> your OpenAPI connector -> **Delete**.

**AWS backend (scripted):**
```bash
make destroy-cfn-connector CFN_REGION="$CFN_REGION"            # dry run - shows what would be deleted
make destroy-cfn-connector CFN_REGION="$CFN_REGION" CONFIRM=yes # actually delete (empties buckets, deletes both stacks)
# raw equivalent: scripts/destroy_backend.sh [--yes]
```

See `CONNECTOR_TEARDOWN.md` for details and the manual CLI equivalent.
