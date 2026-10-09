# =============================================================================
# CI/CD Project Makefile (CloudFormation-based)
# Run `make help` to see all available commands.
# =============================================================================

AWS_REGION ?= us-east-1

# Demo-pipelines repo sync config
RepoName   ?= demo-pipelines-monorepo
BranchName ?= main

.DEFAULT_GOAL := help
.PHONY: help \
        run-dashboard install-dashboard build-dashboard \
        pipelines logs-demo open-app-url \
        deploy-cfn-dashboard plan-cfn-dashboard destroy-cfn-dashboard \
        deploy-cfn-sample-pipelines seed-cfn-samples destroy-cfn-sample-pipelines \
        deploy-cfn-reader \
        track-account untrack-account list-tracked-accounts \
        enable-org-tracking disable-org-tracking \
        deploy-cfn-connector render-quick-app destroy-cfn-connector

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:
	@echo ""
	@echo "CI/CD Project (CloudFormation) — make targets"
	@echo "---------------------------------------------"
	@echo "Dashboard (UI):"
	@echo "  make run-dashboard       Run locally (vite dev server, http://localhost:5173)"
	@echo "  make install-dashboard   npm install"
	@echo "  make build-dashboard     Production build only"
	@echo ""
	@echo "Source control:"
	@echo "  make sync-demo           Commit & push demo-pipelines/ to CodeCommit"
	@echo ""
	@echo "CloudFormation deploy path:"
	@echo "  export CFN_PKG_BUCKET=<your-bucket>   # required for Lambda packaging"
	@echo "  make plan-cfn-dashboard               Package + show change set, no apply"
	@echo "  make deploy-cfn-dashboard [DEVOPS_AGENT_SPACE_ID=<id>]"
	@echo "                                        Deploy the central backend stack (ID enables chat)"
	@echo "  make deploy-cfn-sample-pipelines      Deploy 3 demo pipelines (empty repos)"
	@echo "  make seed-cfn-samples [NAME_PREFIX=sample]   Push sample-apps/* into each repo"
	@echo "  make deploy-cfn-reader CENTRAL_LAMBDA_ROLE_ARN=arn:... PROFILE=<target>"
	@echo "                                        Deploy reader role in a target account"
	@echo "  make destroy-cfn-dashboard / destroy-cfn-sample-pipelines"
	@echo ""
	@echo "Amazon Quick connector (app frontend — see QUICK_APP_QUICKSTART.md):"
	@echo "  make deploy-cfn-connector CONNECTOR_DOMAIN_PREFIX=<unique-prefix>"
	@echo "                                        Deploy backend with the OAuth2 connector on"
	@echo "  make render-quick-app                 Render connector openapi.generated.json + build prompt"
	@echo "  make destroy-cfn-connector [CONFIRM=yes]"
	@echo "                                        Tear down backend+samples (dry-run without CONFIRM=yes)"
	@echo ""
	@echo "Multi-account dashboard:"
	@echo "  make track-account PROFILE=<other-aws-profile> ALIAS=<short-label> [REGION=us-east-1]"
	@echo "                           Deploy reader role in a target account and print the"
	@echo "                           entry to add to the central stack's TrackedAccounts."
	@echo "  make list-tracked-accounts"
	@echo "                           Print the live /accounts API response."
	@echo "  make untrack-account ALIAS=<short-label>"
	@echo "                           Remove a tracked account entry from the central stack."
	@echo "  make enable-org-tracking ROOT_ID=r-xxxx [REGIONS=us-east-1]"
	@echo "                           Auto-discover every account in the AWS Organization"
	@echo "                           via StackSets. New accounts onboard automatically."
	@echo "  make disable-org-tracking"
	@echo "                           Turn off org auto-discovery."
	@echo ""
	@echo "Status / debug:"
	@echo "  make pipelines           List CodePipeline pipelines"
	@echo "  make logs-demo           List recent demo pipeline build log groups"
	@echo "  make open-app-url        Print the CloudFront URL"
	@echo ""

# -----------------------------------------------------------------------------
# Local dashboard (React + Vite)
# -----------------------------------------------------------------------------
DASHBOARD_DIR := frontend

install-dashboard:
	npm --prefix $(DASHBOARD_DIR) install

run-dashboard:
	@echo ">> Starting dashboard at http://localhost:5173"
	npm --prefix $(DASHBOARD_DIR) run dev

build-dashboard:
	npm --prefix $(DASHBOARD_DIR) run build

# -----------------------------------------------------------------------------
# Sync demo-pipelines monorepo to CodeCommit
# -----------------------------------------------------------------------------
# Demo content lives outside this workspace to keep the product folder clean.
# Override with `make ... DEMOS_DIR=/path/to/your/demos` if you want a
# different location. Defaults to a sibling directory next to the repo.
DEMOS_DIR ?= $(abspath $(CURDIR)/../aws-code-suite-observability-demos)

sync-demo:
	@echo ">> Committing and pushing $(DEMOS_DIR)/source-apps/ to CodeCommit"
	@cd $(DEMOS_DIR)/source-apps && \
	  if [ ! -d .git ]; then \
	    git init -b $(BranchName) && \
	    git remote add origin codecommit::$(AWS_REGION)://$(RepoName); \
	  fi && \
	  git add -A && \
	  (git diff --cached --quiet || git commit -m "Update demo pipelines $$(date +%Y-%m-%dT%H:%M:%S)") && \
	  git push -u origin $(BranchName)

# -----------------------------------------------------------------------------
# Status / debug
# -----------------------------------------------------------------------------
pipelines:
	aws codepipeline list-pipelines \
	  --region $(AWS_REGION) \
	  --query 'pipelines[].{Name:name,Updated:updated}' \
	  --output table

logs-demo:
	aws logs describe-log-groups \
	  --log-group-name-prefix /aws/codebuild/demo- \
	  --region $(AWS_REGION) \
	  --query 'logGroups[].logGroupName' --output table

open-app-url:
	@aws cloudformation describe-stacks --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION) \
	  --query 'Stacks[0].Outputs[?OutputKey==`DistributionDomainName`].OutputValue' --output text

# -----------------------------------------------------------------------------
# CloudFormation deploy path.
# Requires a packaging S3 bucket; set CFN_PKG_BUCKET in your env. Create one
# once per region:
#   aws s3 mb s3://cfn-pkg-$$(aws sts get-caller-identity --query Account --output text)-us-east-1
# -----------------------------------------------------------------------------
CFN_DIR        ?= cloudformation
CFN_STACK_NAME ?= pipeline-dashboard
CFN_REGION     ?= us-east-1
# Globally-unique Cognito hosted-domain prefix for the Amazon Quick connector's
# OAuth2 token endpoint. Empty = connector resources are NOT created (the base
# stack is unchanged). Set it to turn the connector path on, e.g.:
#   make deploy-cfn-connector CONNECTOR_DOMAIN_PREFIX=pipeline-dashboard-<account-id>
CONNECTOR_DOMAIN_PREFIX ?=
# Existing AWS DevOps Agent AgentSpace ID for the dashboard chat. Empty = leave
# the stack's current value (chat returns "not configured" until it's set):
#   make deploy-cfn-dashboard DEVOPS_AGENT_SPACE_ID=<agent-space-id>
DEVOPS_AGENT_SPACE_ID ?=
_agent_space_override = $(if $(DEVOPS_AGENT_SPACE_ID),--parameter-overrides DevOpsAgentSpaceId=$(DEVOPS_AGENT_SPACE_ID),)

# Guard so we don't `aws cloudformation package` without a bucket and end up
# with a half-rendered template referencing local paths.
_require-pkg-bucket:
	@if [ -z "$(CFN_PKG_BUCKET)" ]; then \
	  echo "ERROR: CFN_PKG_BUCKET is not set."; \
	  echo "  Create one and export it, e.g.:"; \
	  echo "    aws s3 mb s3://cfn-pkg-$$(aws sts get-caller-identity --query Account --output text)-us-east-1"; \
	  echo "    export CFN_PKG_BUCKET=cfn-pkg-$$(aws sts get-caller-identity --query Account --output text)-us-east-1"; \
	  exit 1; \
	fi

# Validate (no deploy) — show the change set without executing it.
plan-cfn-dashboard: _require-pkg-bucket
	@echo ">> Packaging $(CFN_DIR)/dashboard-backend/template.yaml"
	aws cloudformation package \
	  --template-file $(CFN_DIR)/dashboard-backend/template.yaml \
	  --s3-bucket $(CFN_PKG_BUCKET) \
	  --output-template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION)
	@echo ">> Validating packaged template"
	aws cloudformation validate-template \
	  --template-body file://$(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION) >/dev/null
	@echo ">> Showing change set against stack $(CFN_STACK_NAME) (will not execute)"
	-aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME) \
	  --template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --no-execute-changeset \
	  $(_agent_space_override) \
	  --region $(CFN_REGION)

deploy-cfn-dashboard: _require-pkg-bucket
	@echo ">> Packaging $(CFN_DIR)/dashboard-backend/template.yaml"
	aws cloudformation package \
	  --template-file $(CFN_DIR)/dashboard-backend/template.yaml \
	  --s3-bucket $(CFN_PKG_BUCKET) \
	  --output-template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION)
	@echo ">> Deploying stack $(CFN_STACK_NAME)"
	aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME) \
	  --template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  $(_agent_space_override) \
	  --region $(CFN_REGION)
	@aws cloudformation describe-stacks --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION) \
	  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table

deploy-cfn-sample-pipelines:
	@echo ">> Deploying sample pipelines (CFN)"
	aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME)-samples \
	  --template-file $(CFN_DIR)/sample-pipelines/template.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --region $(CFN_REGION)
	@echo ""
	@echo ">> Pipelines deployed but their CodeCommit repos are empty."
	@echo "   Run 'make seed-cfn-samples' to populate them with starter source."

# Init a temp git repo, commit each cloudformation/sample-pipelines/sample-apps/<dir>,
# and force-push to main on the matching CodeCommit repo.
#
# Override NAME_PREFIX if you deployed the samples stack with a non-default
# NamePrefix. Defaults to "sample" — matching the CFN template default.
seed-cfn-samples: NAME_PREFIX ?= sample
seed-cfn-samples:
	@for s in python-api node-api static-site ; do \
	  REPO_NAME="$(NAME_PREFIX)-$$s" ; \
	  SRC="$(CFN_DIR)/sample-pipelines/sample-apps/$$s" ; \
	  if [ ! -d "$$SRC" ]; then echo "skip $$s: $$SRC not found"; continue; fi ; \
	  echo ">> Seeding $$REPO_NAME from $$SRC"; \
	  WORKDIR=$$(mktemp -d) ; \
	  cp -R "$$SRC/." "$$WORKDIR/" ; \
	  ( cd "$$WORKDIR" && \
	    git init -q -b main && \
	    git -c user.email=cfn@sample-pipelines.local -c user.name=cfn add . && \
	    git -c user.email=cfn@sample-pipelines.local -c user.name=cfn commit -q -m "Seed $$s sample app" && \
	    git push -q --force "codecommit::$(CFN_REGION)://$$REPO_NAME" main ) ; \
	  rm -rf "$$WORKDIR" ; \
	done

deploy-cfn-reader:
	@if [ -z "$(CENTRAL_LAMBDA_ROLE_ARN)" ]; then \
	  echo "Usage: make deploy-cfn-reader CENTRAL_LAMBDA_ROLE_ARN=arn:aws:iam::<central>:role/pipeline-dashboard-stats-lambda-role [PROFILE=<target-profile>]"; \
	  exit 1; \
	fi
	@echo ">> Deploying cross-account reader role in $(if $(PROFILE),profile=$(PROFILE),default profile)"
	aws cloudformation deploy \
	  --stack-name pipeline-dashboard-reader \
	  --template-file $(CFN_DIR)/cross-account-reader/template.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides "CentralLambdaRoleArn=$(CENTRAL_LAMBDA_ROLE_ARN)" \
	  --region $(CFN_REGION) \
	  $(if $(PROFILE),--profile $(PROFILE),)

# Symmetric destroy targets so users aren't left guessing.
destroy-cfn-dashboard:
	aws cloudformation delete-stack --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION)
	aws cloudformation wait stack-delete-complete --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION)

destroy-cfn-sample-pipelines:
	aws cloudformation delete-stack --stack-name $(CFN_STACK_NAME)-samples --region $(CFN_REGION)
	aws cloudformation wait stack-delete-complete --stack-name $(CFN_STACK_NAME)-samples --region $(CFN_REGION)

# -----------------------------------------------------------------------------
# Multi-account dashboard helpers
# -----------------------------------------------------------------------------
PROFILE ?=
ALIAS   ?=
REGION  ?= us-east-1

# Deploy the reader role into a target account via CloudFormation, then print
# the TrackedAccounts entry to add to the central stack.
track-account:
	@if [ -z "$(PROFILE)" ] || [ -z "$(ALIAS)" ]; then \
	  echo "Usage: make track-account PROFILE=<aws-profile-for-target-account> ALIAS=<short-label> [REGION=us-east-1]"; \
	  exit 1; \
	fi
	@echo ">> Resolving central stats Lambda role ARN from stack $(CFN_STACK_NAME)..."
	@CENTRAL_ROLE_ARN=$$(aws cloudformation describe-stacks \
	   --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION) \
	   --query 'Stacks[0].Outputs[?OutputKey==`StatsLambdaRoleArn`].OutputValue' --output text); \
	 if [ -z "$$CENTRAL_ROLE_ARN" ] || [ "$$CENTRAL_ROLE_ARN" = "None" ]; then \
	   echo "Central stack not deployed yet (no StatsLambdaRoleArn output). Run 'make deploy-cfn-dashboard' first."; exit 1; \
	 fi; \
	 echo ">> Deploying PipelineDashboardReader role into account behind profile '$(PROFILE)'..."; \
	 AWS_PROFILE=$(PROFILE) aws cloudformation deploy \
	   --stack-name pipeline-dashboard-reader \
	   --template-file $(CFN_DIR)/cross-account-reader/template.yaml \
	   --capabilities CAPABILITY_NAMED_IAM \
	   --parameter-overrides "CentralLambdaRoleArn=$$CENTRAL_ROLE_ARN" \
	   --region $(REGION); \
	 ROLE_ARN=$$(AWS_PROFILE=$(PROFILE) aws cloudformation describe-stacks \
	   --stack-name pipeline-dashboard-reader --region $(REGION) \
	   --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' --output text); \
	 TARGET_ACCOUNT=$$(AWS_PROFILE=$(PROFILE) aws cloudformation describe-stacks \
	   --stack-name pipeline-dashboard-reader --region $(REGION) \
	   --query 'Stacks[0].Outputs[?OutputKey==`TargetAccountId`].OutputValue' --output text); \
	 echo ""; \
	 echo "==============================================================="; \
	 echo "Reader role deployed in target account $$TARGET_ACCOUNT:"; \
	 echo "  $$ROLE_ARN"; \
	 echo ""; \
	 echo "Add this entry to the central stack's TrackedAccounts parameter"; \
	 echo "(a JSON list), then re-run 'make deploy-cfn-dashboard':"; \
	 echo ""; \
	 echo "    {"; \
	 echo "      \"account_id\": \"$$TARGET_ACCOUNT\","; \
	 echo "      \"alias\":      \"$(ALIAS)\","; \
	 echo "      \"region\":     \"$(REGION)\","; \
	 echo "      \"role_arn\":   \"$$ROLE_ARN\""; \
	 echo "    }"; \
	 echo "==============================================================="

untrack-account:
	@if [ -z "$(ALIAS)" ]; then \
	  echo "Usage: make untrack-account ALIAS=<short-label>"; \
	  exit 1; \
	fi
	@echo ">> Remove the entry with alias='$(ALIAS)' from the central stack's"; \
	 echo "   TrackedAccounts parameter, then re-run:"; \
	 echo ""; \
	 echo "       make deploy-cfn-dashboard"; \
	 echo ""; \
	 echo "   In the target account, delete the reader stack to remove the role:"; \
	 echo "       AWS_PROFILE=<that-account> aws cloudformation delete-stack \\"; \
	 echo "         --stack-name pipeline-dashboard-reader --region $(REGION)"; \
	 echo "   (or leave it dormant — it's harmless)."

list-tracked-accounts:
	@URL=$$(aws cloudformation describe-stacks --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION) \
	   --query 'Stacks[0].Outputs[?OutputKey==`StatsApiUrl`].OutputValue' --output text 2>/dev/null | sed 's|/stats||'); \
	 if [ -z "$$URL" ] || [ "$$URL" = "None" ]; then echo "Dashboard stack not deployed yet."; exit 1; fi; \
	 echo ">> GET $$URL/accounts (SigV4-signed)"; \
	 python3 scripts/awscall.py GET "$$URL/accounts" | python3 -m json.tool

# -----------------------------------------------------------------------------
# AWS Organizations auto-discovery (CloudFormation StackSets)
# -----------------------------------------------------------------------------
ROOT_ID ?=
REGIONS ?= us-east-1

# Redeploy the central stack with OrgEnabled=true so it provisions the
# PipelineDashboardReader StackSet across the org; the central stats Lambda
# then auto-discovers accounts at runtime.
enable-org-tracking: _require-pkg-bucket
	@if [ -z "$(ROOT_ID)" ]; then \
	  echo "Usage: make enable-org-tracking ROOT_ID=r-xxxx [REGIONS=us-east-1,us-west-2]"; \
	  echo ""; \
	  echo "Find your org root ID: aws organizations list-roots --query 'Roots[0].Id' --output text"; \
	  exit 1; \
	fi
	@echo ">> Enabling Organizations auto-discovery (OrgEnabled=true)..."
	aws cloudformation package \
	  --template-file $(CFN_DIR)/dashboard-backend/template.yaml \
	  --s3-bucket $(CFN_PKG_BUCKET) \
	  --output-template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION)
	aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME) \
	  --template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides OrgEnabled=true OrgRootId=$(ROOT_ID) "OrgRegions=$(REGIONS)" \
	  --region $(CFN_REGION)

disable-org-tracking: _require-pkg-bucket
	@echo ">> Disabling Organizations auto-discovery (OrgEnabled=false)."
	aws cloudformation package \
	  --template-file $(CFN_DIR)/dashboard-backend/template.yaml \
	  --s3-bucket $(CFN_PKG_BUCKET) \
	  --output-template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION)
	aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME) \
	  --template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides OrgEnabled=false \
	  --region $(CFN_REGION)

# -----------------------------------------------------------------------------
# Amazon Quick connector (OAuth2 + JWT) — Part 2 frontend path.
# See cloudformation/dashboard-backend/QUICK_APP_QUICKSTART.md for the full
# deploy-and-build walkthrough.
# -----------------------------------------------------------------------------

# Deploy the backend WITH the connector resources turned on. Same as
# deploy-cfn-dashboard but sets ConnectorAuthDomainPrefix.
deploy-cfn-connector: _require-pkg-bucket
	@if [ -z "$(CONNECTOR_DOMAIN_PREFIX)" ]; then \
	  echo "ERROR: CONNECTOR_DOMAIN_PREFIX is not set (globally-unique Cognito domain prefix)."; \
	  echo "  e.g. make deploy-cfn-connector CONNECTOR_DOMAIN_PREFIX=pipeline-dashboard-$$(aws sts get-caller-identity --query Account --output text)"; \
	  exit 1; \
	fi
	@echo ">> Packaging $(CFN_DIR)/dashboard-backend/template.yaml"
	aws cloudformation package \
	  --template-file $(CFN_DIR)/dashboard-backend/template.yaml \
	  --s3-bucket $(CFN_PKG_BUCKET) \
	  --output-template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --region $(CFN_REGION)
	@echo ">> Deploying stack $(CFN_STACK_NAME) with connector (prefix=$(CONNECTOR_DOMAIN_PREFIX))"
	aws cloudformation deploy \
	  --stack-name $(CFN_STACK_NAME) \
	  --template-file $(CFN_DIR)/dashboard-backend/.packaged.yaml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides ConnectorAuthDomainPrefix=$(CONNECTOR_DOMAIN_PREFIX) \
	  --region $(CFN_REGION)
	@aws cloudformation describe-stacks --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION) \
	  --query 'Stacks[0].Outputs[?starts_with(OutputKey, `Connector`)].{Key:OutputKey,Value:OutputValue}' --output table

# Render the import-ready connector OpenAPI spec + Quick app build prompt from
# the deployed stack outputs (writes connector/*.generated.* — gitignored).
render-quick-app:
	python3 scripts/render_quick_app.py --stack-name $(CFN_STACK_NAME) --region $(CFN_REGION)

# Tear down the backend + samples (empties S3 buckets first). Dry-run by
# default; pass CONFIRM=yes to actually delete. The Quick app + connector must
# be deleted manually in the Quick console (see CONNECTOR_TEARDOWN.md).
destroy-cfn-connector:
	scripts/destroy_backend.sh --region $(CFN_REGION) $(if $(filter yes,$(CONFIRM)),--yes,)
