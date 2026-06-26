# Project conventions — aws-code-suite-observability

A Terraform + React project that observes AWS CodePipeline across accounts.
Treat these as defaults; deviate only with a clear reason.

## Repo layout

- `terraform/dashboard-backend/`   — central Lambda + API Gateway + DynamoDB
- `terraform/sample-pipelines/` — 3 demo CodePipelines (Python/Node/static) for the dashboard
- `terraform/cross-account-reader/` — IAM reader role deployed into target accounts
- `dashboard/`                     — React + Vite UI (Tailwind), run locally
- `scripts/`                       — Python helpers (e.g. `new-pipeline.py`)
- Demo content lives outside the repo at `$HOME/Desktop/dashboard-demos`

## Workflow — always use the Makefile

Do not invent new `terraform apply` or `aws s3 sync` invocations. Use:

- `make plan-dashboard` / `make deploy-dashboard`
- `make deploy-sample-pipelines` — 3 demo pipelines so the dashboard has data
- `make run-dashboard`      — local dev server on :5173 (the dashboard is local-only)
- `make track-account PROFILE=… ALIAS=…` — onboard another AWS account
- `make tf-fmt` before committing Terraform changes

Run `make help` if unsure.

## Terraform

- Format with `terraform fmt` (or `make tf-fmt`) before saving.
- Pin provider versions; do not run `init -upgrade` casually.
- Keep resources in the smallest module that owns them. Pass values between
  stacks via outputs the Makefile reads.
- IAM: prefer least-privilege resource ARNs over `"*"`. The reader role in
  `cross-account-reader` should stay read-only.
- Tag every resource with at least `Project = "aws-code-suite-observability"`.

## Dashboard (React + Vite)

- API base URL comes from `VITE_API_URL` at build time. Never hardcode.
- API calls live in `src/pipelineService.js`; keep `App.jsx` free of `fetch`.
- Tailwind utility classes only; no inline `style={…}` unless dynamic.

## Security

- A `checkov-on-save` Kiro hook runs on Terraform edits. Fix or justify
  findings in a comment (`# checkov:skip=CKV_AWS_123: reason`) rather than
  ignoring them silently.
- Never commit `.env`, `*.tfvars` with secrets, or `terraform.tfstate*`.
  These are already gitignored — keep it that way.

## When generating code

- Match existing file style (2-space indent in HCL, 2-space in JSX).
- Prefer adding to an existing module/file over creating a new one.
- The dashboard is local-only: after `deploy-dashboard`, run `make run-dashboard`
  to serve it on http://localhost:5173 against the live API.
