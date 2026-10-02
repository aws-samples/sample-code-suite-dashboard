# Teardown — Amazon Quick app + connector backend

The "destroy" counterpart to `CONNECTOR_DEPLOY_RUNBOOK.md`. There are two
halves, and only one of them is scriptable:

| Layer | Created by | Removed by |
|---|---|---|
| App in Quick + connector | Quick console (manual) | Quick console (manual) — no API/CLI exists |
| AWS backend (stacks, Cognito, API, data lake) | CloudFormation | `scripts/destroy_backend.sh` or `aws cloudformation delete-stack` |

> Amazon Quick apps have **no public create/delete API** — management is
> console-only. So the app + connector must be deleted by hand; there is no
> `destroy` script for them. The AWS backend is fully scripted.

Do the manual Quick steps **first**, then the AWS teardown — once the backend
stack is gone, the Cognito user pool is deleted and the connector's credentials
stop working, so deleting the connector afterward is more confusing.

---

## 1. Delete the app in Quick (manual)

1. Open the app in the Quick console.
2. Open **App settings → Overview**.
3. Choose **Delete**, confirm.

## 2. Delete the connector (manual)

1. Quick console → **Connectors**.
2. Open the connector you imported (the OpenAPI one).
3. Choose **Delete**, type the name to confirm.

Removing the app does not remove the connector, and vice versa — delete both.

---

## 3. Tear down the AWS backend (scripted)

⚠️ **Destructive and hard to reverse.** This deletes:
- all captured pipeline history in the data-lake S3 bucket,
- the Cognito user pool + app client (connector credentials become invalid),
- the HTTP API, both Lambdas, Glue/Athena, Firehose, EventBridge rules, alarms,
- the sample pipelines + their CodeCommit repos (if the samples stack exists).

Use the helper, which empties the S3 buckets first (CloudFormation can't delete
non-empty buckets) and requires explicit confirmation:

The script uses your configured AWS credentials (AWS_PROFILE / env / default
profile) and region.

```bash
# dry run — shows what would be deleted, changes nothing
scripts/destroy_backend.sh

# actually destroy (requires --yes)
scripts/destroy_backend.sh --yes
```

### Manual equivalent (if you prefer raw CLI)

```bash
# Assumes your AWS CLI is already configured (AWS_PROFILE / env / default).
REGION=us-west-2   # or your deploy region

# samples first (has CodeCommit repos + its own artifacts bucket)
aws s3 rm "s3://sample-pipelines-artifacts-$(aws sts get-caller-identity --query Account --output text)" --recursive
aws cloudformation delete-stack --stack-name pipeline-dashboard-samples --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name pipeline-dashboard-samples --region "$REGION"

# backend
aws s3 rm "s3://pipeline-dashboard-data-$(aws sts get-caller-identity --query Account --output text)" --recursive
aws cloudformation delete-stack --stack-name pipeline-dashboard --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name pipeline-dashboard --region "$REGION"
```

### Keep just the connector, drop the rest

If you only want to remove the connector auth path but keep the dashboard
backend, redeploy with an empty domain prefix instead of deleting the stack:

```bash
aws cloudformation deploy \
  --stack-name pipeline-dashboard \
  --template-file .packaged.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ConnectorAuthDomainPrefix="" \
  --region "$REGION"
```

## 4. Leftovers to check

- **Packaging bucket** (`aws-code-observability-cfn-artifacts-<acct>-<region>`)
  is not part of either stack — delete it separately if you're done:
  `aws s3 rb s3://<bucket> --force`.
- **Rendered artifacts** (`connector/*.generated.*`) are local + gitignored;
  delete with `rm` if you want them gone.
- **CloudWatch log groups** for the Lambdas/API are set with retention and will
  age out; delete manually if you want them gone immediately.
