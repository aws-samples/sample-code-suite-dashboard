# =============================================================================
# CI/CD Project Makefile (Terraform-based)
# Run `make help` to see all available commands.
# =============================================================================

AWS_REGION ?= us-east-1
# TF_DIR is the path to a Terraform root module.
# Default targets the dashboard backend.
TF_DIR ?= terraform/dashboard-backend

# Demo content lives outside this workspace to keep the product folder clean.
DEMOS_DIR ?= $(HOME)/Desktop/dashboard-demos

# Demo-pipelines repo sync config
RepoName   ?= demo-pipelines-monorepo
BranchName ?= main

.DEFAULT_GOAL := help
.PHONY: help \
        deploy deploy-main deploy-dashboard deploy-demo deploy-all \
        destroy destroy-main destroy-dashboard destroy-demo \
        deploy-sample-pipelines destroy-sample-pipelines plan-sample-pipelines \
        plan plan-main plan-dashboard plan-demo \
        run-dashboard install-dashboard build-dashboard \
        sync-demo status pipelines logs-main logs-demo \
        open-app-url tf-fmt tf-validate \
        new-pipeline new-pipeline-dry \
        track-account untrack-account list-tracked-accounts

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:
	@echo ""
	@echo "CI/CD Project (Terraform) — make targets"
	@echo "----------------------------------------"
	@echo "Plan / Apply (set TF_DIR to any Terraform root module):"
	@echo "  make plan   TF_DIR=terraform/dashboard-backend"
	@echo "  make deploy TF_DIR=demo/react-cicd"
	@echo ""
	@echo "Convenience (named stacks):"
	@echo "  make plan-main      / make deploy-main      / make destroy-main"
	@echo "  make plan-demo      / make deploy-demo      / make destroy-demo"
	@echo "  make plan-dashboard / make deploy-dashboard / make destroy-dashboard"
	@echo "  make deploy-all     Apply all root modules in order"
	@echo ""
	@echo "Dashboard (UI):"
	@echo "  make run-dashboard       Run locally (vite dev server, http://localhost:5173)"
	@echo "  make install-dashboard   npm install"
	@echo "  make build-dashboard     Production build only"
	@echo ""
	@echo "Source control:"
	@echo "  make sync-demo           Commit & push demo-pipelines/ to CodeCommit"
	@echo ""
	@echo "Generate:"
	@echo "  make new-pipeline        Create a random pipeline (framework + name) and apply"
	@echo "  make new-pipeline-dry    Scaffold + edit Terraform, no apply"
	@echo "  make new-pipeline FRAMEWORK=python NAME=fancy-svc"
	@echo ""
	@echo "Sample pipelines (in-repo, for demos / blog):"
	@echo "  make plan-sample-pipelines     Plan the sample stack"
	@echo "  make deploy-sample-pipelines   Create 3 demo CodePipelines + seed source"
	@echo "  make destroy-sample-pipelines  Tear them down"
	@echo ""
	@echo "Multi-account dashboard:"
	@echo "  make track-account PROFILE=<other-aws-profile> ALIAS=<short-label> [REGION=us-east-1]"
	@echo "                           Deploy reader role in a target account and add it"
	@echo "                           to tracked_accounts in the central stack."
	@echo "  make list-tracked-accounts"
	@echo "                           Print the live /accounts API response."
	@echo "  make untrack-account ALIAS=<short-label>"
	@echo "                           Remove a tracked account entry from the central stack."
	@echo "  make enable-org-tracking ROOT_ID=r-xxxx [OU_IDS=ou-a,ou-b] [REGIONS=us-east-1]"
	@echo "                           Auto-discover every account in the AWS Organization"
	@echo "                           via StackSets. New accounts onboard automatically."
	@echo "  make disable-org-tracking"
	@echo "                           Turn off org auto-discovery."
	@echo ""
	@echo "Status / debug:"
	@echo "  make status              Show terraform outputs for all 3 stacks"
	@echo "  make pipelines           List CodePipeline pipelines"
	@echo "  make logs-main           Tail the latest react-cicd build logs"
	@echo "  make logs-demo           List recent demo pipeline build log groups"
	@echo "  make open-app-url        Print the CloudFront URL"
	@echo ""
	@echo "Terraform:"
	@echo "  make tf-fmt              Format all .tf files"
	@echo "  make tf-validate TF_DIR=terraform/dashboard-backend"
	@echo ""

# -----------------------------------------------------------------------------
# Generic plan / apply / destroy (driven by STACK)
# -----------------------------------------------------------------------------
plan:
	terraform -chdir=$(TF_DIR) init -upgrade=false
	terraform -chdir=$(TF_DIR) plan

deploy:
	terraform -chdir=$(TF_DIR) init -upgrade=false
	terraform -chdir=$(TF_DIR) apply -auto-approve

destroy:
	terraform -chdir=$(TF_DIR) destroy -auto-approve

# -----------------------------------------------------------------------------
# Per-stack convenience aliases
# -----------------------------------------------------------------------------
plan-main:
	$(MAKE) plan TF_DIR=$(DEMOS_DIR)/demo/react-cicd

plan-demo:
	$(MAKE) plan TF_DIR=$(DEMOS_DIR)/demo/pipelines

plan-dashboard:
	$(MAKE) plan TF_DIR=terraform/dashboard-backend

deploy-main:
	$(MAKE) deploy TF_DIR=$(DEMOS_DIR)/demo/react-cicd

deploy-demo:
	$(MAKE) deploy TF_DIR=$(DEMOS_DIR)/demo/pipelines

deploy-dashboard:
	$(MAKE) deploy TF_DIR=terraform/dashboard-backend

deploy-all: deploy-main deploy-demo deploy-dashboard
	@echo ">> All root modules applied. Run 'make run-dashboard' to serve the UI locally."

destroy-main:
	$(MAKE) destroy TF_DIR=$(DEMOS_DIR)/demo/react-cicd

destroy-demo:
	$(MAKE) destroy TF_DIR=$(DEMOS_DIR)/demo/pipelines

destroy-dashboard:
	$(MAKE) destroy TF_DIR=terraform/dashboard-backend

# -----------------------------------------------------------------------------
# Sample pipelines (in-repo demo — populates the dashboard with real data)
# -----------------------------------------------------------------------------
plan-sample-pipelines:
	$(MAKE) plan TF_DIR=terraform/sample-pipelines

deploy-sample-pipelines:
	$(MAKE) deploy TF_DIR=terraform/sample-pipelines
	@echo ""
	@echo ">> Sample pipelines deployed. Refresh http://localhost:5173 to see them."

destroy-sample-pipelines:
	$(MAKE) destroy TF_DIR=terraform/sample-pipelines

# -----------------------------------------------------------------------------
# Local dashboard (React + Vite)
# -----------------------------------------------------------------------------
DASHBOARD_DIR := dashboard

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
status:
	@for d in $(DEMOS_DIR)/demo/react-cicd $(DEMOS_DIR)/demo/pipelines terraform/dashboard-backend; do \
	  echo ""; echo "=== $$d ==="; \
	  terraform -chdir=$$d output 2>/dev/null || echo "  (not applied)"; \
	done

pipelines:
	aws codepipeline list-pipelines \
	  --region $(AWS_REGION) \
	  --query 'pipelines[].{Name:name,Updated:updated}' \
	  --output table

logs-main:
	@PROJ=$$(terraform -chdir=demo/react-cicd output -raw pipeline_name 2>/dev/null | sed 's/-pipeline$$/-build/'); \
	echo ">> Tailing logs for CodeBuild project $$PROJ"; \
	aws logs tail /aws/codebuild/$$PROJ --follow --region $(AWS_REGION)

logs-demo:
	aws logs describe-log-groups \
	  --log-group-name-prefix /aws/codebuild/demo- \
	  --region $(AWS_REGION) \
	  --query 'logGroups[].logGroupName' --output table

open-app-url:
	@terraform -chdir=demo/react-cicd output -raw distribution_domain_name

# -----------------------------------------------------------------------------
# Terraform helpers
# -----------------------------------------------------------------------------
tf-fmt:
	terraform -chdir=terraform fmt -recursive

tf-validate:
	terraform -chdir=$(TF_DIR) init -backend=false -upgrade=false
	terraform -chdir=$(TF_DIR) validate

# -----------------------------------------------------------------------------
# Generate a new random pipeline
# -----------------------------------------------------------------------------
FRAMEWORK ?=
NAME      ?=
NEW_FLAGS := $(if $(FRAMEWORK),--framework $(FRAMEWORK)) $(if $(NAME),--name $(NAME))

new-pipeline:
	python3 scripts/new-pipeline.py $(NEW_FLAGS)

new-pipeline-dry:
	python3 scripts/new-pipeline.py --dry-run $(NEW_FLAGS)

# -----------------------------------------------------------------------------
# Multi-account dashboard helpers
# -----------------------------------------------------------------------------
PROFILE ?=
ALIAS   ?=
REGION  ?= us-east-1

track-account:
	@if [ -z "$(PROFILE)" ] || [ -z "$(ALIAS)" ]; then \
	  echo "Usage: make track-account PROFILE=<aws-profile-for-target-account> ALIAS=<short-label> [REGION=us-east-1]"; \
	  exit 1; \
	fi
	@echo ">> Deploying PipelineDashboardReader role into account behind profile '$(PROFILE)'..."
	AWS_PROFILE=$(PROFILE) terraform -chdir=terraform/cross-account-reader init -upgrade=false
	AWS_PROFILE=$(PROFILE) terraform -chdir=terraform/cross-account-reader apply -auto-approve -var "region=$(REGION)"
	@ROLE_ARN=$$(AWS_PROFILE=$(PROFILE) terraform -chdir=terraform/cross-account-reader output -raw role_arn); \
	 ACCOUNT_ID=$$(AWS_PROFILE=$(PROFILE) terraform -chdir=terraform/cross-account-reader output -raw target_account_id); \
	 echo ""; \
	 echo "==============================================================="; \
	 echo "Reader role deployed in target account $$ACCOUNT_ID:"; \
	 echo "  $$ROLE_ARN"; \
	 echo ""; \
	 echo "Add this entry to terraform/dashboard-backend/variables.tf"; \
	 echo "(under default = [...] in tracked_accounts), then run:"; \
	 echo ""; \
	 echo "    make deploy-dashboard"; \
	 echo ""; \
	 echo "    {"; \
	 echo "      account_id = \"$$ACCOUNT_ID\""; \
	 echo "      alias      = \"$(ALIAS)\""; \
	 echo "      region     = \"$(REGION)\""; \
	 echo "      role_arn   = \"$$ROLE_ARN\""; \
	 echo "    },"; \
	 echo "==============================================================="

untrack-account:
	@if [ -z "$(ALIAS)" ]; then \
	  echo "Usage: make untrack-account ALIAS=<short-label>"; \
	  exit 1; \
	fi
	@echo ">> Use \$$EDITOR to remove the entry with alias='$(ALIAS)' from"; \
	 echo "   terraform/dashboard-backend/variables.tf, then run:"; \
	 echo ""; \
	 echo "       make deploy-dashboard"; \
	 echo ""; \
	 echo "   In the target account, run:"; \
	 echo "       AWS_PROFILE=<that-account> make -C $(PWD) untrack-role"; \
	 echo "   to delete the IAM role itself (or leave it dormant — it's harmless)."

# Tear down the reader role in a target account.
untrack-role:
	@if [ -z "$(PROFILE)" ]; then \
	  echo "Usage: make untrack-role PROFILE=<aws-profile-for-target-account>"; \
	  exit 1; \
	fi
	AWS_PROFILE=$(PROFILE) terraform -chdir=terraform/cross-account-reader destroy -auto-approve

list-tracked-accounts:
	@URL=$$(terraform -chdir=terraform/dashboard-backend output -raw stats_api_url 2>/dev/null | sed 's|/stats||'); \
	 if [ -z "$$URL" ]; then echo "Dashboard stack not deployed yet."; exit 1; fi; \
	 echo ">> GET $$URL/accounts (SigV4-signed)"; \
	 python3 scripts/awscall.py GET "$$URL/accounts" | python3 -m json.tool

# -----------------------------------------------------------------------------
# AWS Organizations auto-discovery
# -----------------------------------------------------------------------------
ROOT_ID ?=
OU_IDS  ?=
REGIONS ?= us-east-1

enable-org-tracking:
	@if [ -z "$(ROOT_ID)" ]; then \
	  echo "Usage: make enable-org-tracking ROOT_ID=r-xxxx [OU_IDS=ou-xxxx,ou-yyyy] [REGIONS=us-east-1,us-west-2]"; \
	  echo ""; \
	  echo "Find your org root ID: aws organizations list-roots --query 'Roots[0].Id' --output text"; \
	  echo "Find your OU IDs:      aws organizations list-organizational-units-for-parent --parent-id <root-id>"; \
	  exit 1; \
	fi
	@echo ">> Enabling Organizations auto-discovery..."
	@echo "   This will deploy the PipelineDashboardReader role to every account in the org via StackSets,"
	@echo "   then the central stats Lambda will auto-discover them at runtime."
	@OU_TF=$$(if [ -n "$(OU_IDS)" ]; then echo "ou_ids=[\"$$(echo $(OU_IDS) | sed 's/,/\",\"/g')\"]"; else echo "ou_ids=[]"; fi); \
	 REG_TF=$$(echo "regions=[\"$$(echo $(REGIONS) | sed 's/,/\",\"/g')\"]"); \
	 terraform -chdir=terraform/dashboard-backend apply -auto-approve \
	   -var "tracked_organization={enabled=true,organization_root_id=\"$(ROOT_ID)\",$$OU_TF,$$REG_TF}"

disable-org-tracking:
	@echo ">> Disabling Organizations auto-discovery (StackSet instances are removed; the IAM role lingers in target accounts but is harmless)."
	terraform -chdir=terraform/dashboard-backend apply -auto-approve \
	  -var 'tracked_organization={enabled=false}'
