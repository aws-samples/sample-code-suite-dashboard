# Connector Deploy Runbook

Deploys the connector-only OAuth path (Cognito + JWT authorizer + `/connector/*`
routes) alongside the existing dashboard backend, then wires it into an Amazon
Quick OpenAPI connector. This is Part 1 (backend) of the two-part solution; the
Quick app itself (Part 2) is built from `connector/QUICK_APP_PROMPT.generated.md`.

> Assumes your AWS CLI is already configured for your target account (via
> `AWS_PROFILE`, environment variables, or your default profile). Substitute
> your own region and a globally-unique domain prefix below.

## 0. Preconditions

- AWS CLI configured for the account you want to deploy into.
- Amazon Quick enabled in that account (for the connector import at the end).
- A packaging S3 bucket for Lambda zips (created in step 1).

If you use a named profile, export `AWS_PROFILE=<your-profile>` first so every
command picks it up. Set `CFN_REGION` to a Quick-supported region (e.g.
`us-west-2`). `CONNECTOR_DOMAIN_PREFIX` must be a globally-unique Cognito domain
prefix (lowercase, digits, hyphens).

```bash
export CFN_REGION=<your-region>
export CFN_STACK_NAME=pipeline-dashboard
export CONNECTOR_DOMAIN_PREFIX=pipeline-dashboard-$(aws sts get-caller-identity --query Account --output text)
```

Confirm which account and region you are about to deploy into before running
anything mutating:

```bash
aws sts get-caller-identity --output table
echo "Region: $CFN_REGION"
```

## 1. Packaging bucket (one-time)

```bash
export CFN_PKG_BUCKET=aws-code-observability-cfn-artifacts-$(aws sts get-caller-identity --query Account --output text)-${CFN_REGION}
aws s3 mb "s3://$CFN_PKG_BUCKET" --region "$CFN_REGION"
```

## 2. Package

```bash
cd cloudformation/dashboard-backend

aws cloudformation package \
  --template-file template.yaml \
  --s3-bucket "$CFN_PKG_BUCKET" \
  --output-template-file .packaged.yaml \
  --region "$CFN_REGION"
```

## 3. Deploy

The new `ConnectorAuthDomainPrefix` parameter is what turns the connector
resources on. Existing parameters keep their defaults.

```bash
aws cloudformation deploy \
  --stack-name "$CFN_STACK_NAME" \
  --template-file .packaged.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ConnectorAuthDomainPrefix="$CONNECTOR_DOMAIN_PREFIX" \
  --region "$CFN_REGION"
```

If the stack already exists from a prior deploy, this is an update — it adds the
Cognito + connector resources and leaves the rest in place.

## 4. Read the outputs

```bash
aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION" \
  --query 'Stacks[0].Outputs[?starts_with(OutputKey, `Connector`)].{Key:OutputKey,Value:OutputValue}' \
  --output table
```

Record `ConnectorTokenUrl`, `ConnectorClientId`, `ConnectorBaseUrl`, `ConnectorScope`.

## 5. Fetch the client secret (not a stack output on purpose)

```bash
POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$CFN_REGION" \
  --query "UserPools[?Name=='${CFN_STACK_NAME}-connector'].Id | [0]" --output text)

CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ConnectorClientId`].OutputValue' --output text)

aws cognito-idp describe-user-pool-client \
  --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" --region "$CFN_REGION" \
  --query 'UserPoolClient.ClientSecret' --output text
```

Treat the secret as sensitive — it's the connector's OAuth credential.

## 6. Smoke-test the OAuth + connector path (before touching Quick)

```bash
TOKEN_URL=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ConnectorTokenUrl`].OutputValue' --output text)
BASE_URL=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" --region "$CFN_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ConnectorBaseUrl`].OutputValue' --output text)
CLIENT_SECRET=<paste from step 5>

ACCESS_TOKEN=$(curl -s -X POST "$TOKEN_URL" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d 'grant_type=client_credentials&scope=pipeline-dashboard/read' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$BASE_URL/stats"     | python3 -m json.tool
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$BASE_URL/accounts"  | python3 -m json.tool
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$BASE_URL/pipelines?pageSize=5" | python3 -m json.tool

curl -s -o /dev/null -w '%{http_code}\n' "$BASE_URL/stats"
```

This gets an access token with the client credentials grant, calls each
connector route with it, then calls `/stats` with no token to confirm auth is
enforced. Expected: the authorized calls return JSON bodies matching the route
contract, and the final unauthenticated call **must** print `401`. If you
deployed the optional sample pipelines you'll see rows; otherwise `/pipelines`
returns an empty `items` list, which is still a valid pass.

## 7. Render the connector artifacts

Instead of hand-editing `openapi.json`, run the render script — it reads the
stack outputs and writes an import-ready spec plus the Quick app build prompt,
both with your live values filled in:

Add `--region`/`--profile` only if they differ from your configured defaults:

```bash
python3 scripts/render_quick_app.py --stack-name "$CFN_STACK_NAME"
```

This produces (gitignored, account-specific):
- `connector/openapi.generated.json` — import this into Quick.
- `connector/QUICK_APP_PROMPT.generated.md` — the phased build prompt.

## 8. Create the Amazon Quick connector

1. Amazon Quick console → **Connectors** → **Create for your team** →
   **OpenAPI Specification** → import `connector/openapi.generated.json`.
2. Choose **Service authentication (client credentials)** and enter the
   `ConnectorClientId` + client secret (from step 5); scope `pipeline-dashboard/read`.
3. Review the four generated actions (getStats, getAccounts, getPipelines, getPipeline).

## 9. Build the Quick app

Follow `connector/QUICK_APP_PROMPT.generated.md` — point the Quick app builder
at your local clone (`frontend/src/App.jsx` as the visual reference) and work
through the phases. See that file's Teardown section (and `CONNECTOR_TEARDOWN.md`)
for how to delete the app + connector when you're done.

## 10. First validation of the array-schema risk

The single biggest unknown: Quick's OpenAPI connector documents **array types as
unsupported**, and our responses use array fields (`items`, `stages`, `history`).
Watch the connector import (step 8.1) closely:

- **If the import validates and the actions work** → the constraint is about
  array-typed *parameters*, not array response fields; proceed.
- **If import fails on the array schemas** → pivot options, in order of
  preference: (a) return the page as a JSON-encoded string field the app parses;
  (b) flatten to numbered fields; (c) switch that operation to the REST API
  connector type instead of schema-derived OpenAPI actions.

Report which happened — it determines the next build step.

## Rollback

The connector resources are gated on `ConnectorAuthDomainPrefix`. To remove just
the connector path (keeping the dashboard backend), redeploy with an empty prefix:

```bash
aws cloudformation deploy \
  --stack-name "$CFN_STACK_NAME" \
  --template-file .packaged.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ConnectorAuthDomainPrefix="" \
  --region "$CFN_REGION"
```

To tear down everything (backend + samples), use the guarded destroy script,
which empties the S3 buckets first:

```bash
scripts/destroy_backend.sh            # dry run
scripts/destroy_backend.sh --yes      # actually delete
```

Delete the Quick app + connector separately in the Quick console — see
`CONNECTOR_TEARDOWN.md`.
