#!/usr/bin/env bash
#
# destroy_backend.sh — tear down the AWS backend for the Code Suite dashboard.
#
# Deletes the pipeline-dashboard stack (and pipeline-dashboard-samples if it
# exists), emptying their S3 buckets first because CloudFormation cannot delete
# non-empty buckets.
#
# SAFETY:
#   - Dry-run by default. Pass --yes to actually delete.
#   - Prints the target account + region and refuses to run against an account
#     you did not confirm (pass --account <id> to assert the expected account).
#   - Only touches the two known stacks and their known buckets.
#
# This is DESTRUCTIVE and hard to reverse: it removes captured pipeline history,
# the Cognito user pool (invalidating connector credentials), and all backend
# resources. Deleting the Quick app + connector is a separate MANUAL step in the
# Quick console — see CONNECTOR_TEARDOWN.md.
#
# Uses the standard AWS credential chain (AWS_PROFILE / env / default profile).
# --profile and --region are optional overrides.
#
# Usage:
#   scripts/destroy_backend.sh                       # dry run, default creds
#   scripts/destroy_backend.sh --yes                 # destroy, default creds
#   scripts/destroy_backend.sh --region us-west-2 --yes
#   scripts/destroy_backend.sh --account 123456789012 --yes   # assert account

set -euo pipefail

PROFILE=""
REGION=""
STACK="pipeline-dashboard"
SAMPLES_STACK="pipeline-dashboard-samples"
CONFIRM="no"
EXPECT_ACCOUNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --stack-name) STACK="$2"; shift 2 ;;
    --account) EXPECT_ACCOUNT="$2"; shift 2 ;;
    --yes) CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

AWS=(aws)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

# Region precedence: --region, then AWS_REGION / AWS_DEFAULT_REGION, then the
# active profile's configured region.
if [[ -z "$REGION" ]]; then
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi
if [[ -z "$REGION" ]]; then
  REGION="$("${AWS[@]}" configure get region 2>/dev/null || true)"
fi
if [[ -z "$REGION" ]]; then
  echo "ABORT: no region found. Pass --region, or set AWS_REGION / your profile's region." >&2
  exit 1
fi

account_id="$("${AWS[@]}" sts get-caller-identity --query Account --output text --region "$REGION")"

echo "=================================================================="
echo " Target account : $account_id"
echo " Target region  : $REGION"
echo " Stacks         : $STACK, $SAMPLES_STACK (if present)"
echo " Mode           : $([[ "$CONFIRM" == yes ]] && echo 'DESTROY (--yes)' || echo 'DRY RUN (no --yes)')"
echo "=================================================================="

if [[ -n "$EXPECT_ACCOUNT" && "$EXPECT_ACCOUNT" != "$account_id" ]]; then
  echo "ABORT: resolved account ($account_id) != --account ($EXPECT_ACCOUNT)." >&2
  exit 1
fi

stack_exists() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$1" --region "$REGION" >/dev/null 2>&1
}

empty_bucket() {
  local bucket="$1"
  if "${AWS[@]}" s3 ls "s3://$bucket" >/dev/null 2>&1; then
    if [[ "$CONFIRM" == yes ]]; then
      echo ">> emptying s3://$bucket"
      "${AWS[@]}" s3 rm "s3://$bucket" --recursive
    else
      local n
      n="$("${AWS[@]}" s3 ls "s3://$bucket" --recursive 2>/dev/null | grep -c . || true)"
      echo "   [dry-run] would empty s3://$bucket (~${n} objects)"
    fi
  else
    echo "   (bucket s3://$bucket not found, skipping)"
  fi
}

delete_stack() {
  local stack="$1"
  if ! stack_exists "$stack"; then
    echo "   (stack $stack not found, skipping)"
    return
  fi
  if [[ "$CONFIRM" == yes ]]; then
    echo ">> deleting stack $stack"
    "${AWS[@]}" cloudformation delete-stack --stack-name "$stack" --region "$REGION"
    echo "   waiting for delete-complete..."
    "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"
    echo "   $stack deleted."
  else
    echo "   [dry-run] would delete stack $stack"
  fi
}

# --- Samples stack (delete first: has CodeCommit repos + artifacts bucket) ---
# Samples artifacts bucket is "<prefix>-pipelines-artifacts-<account>" (no
# region suffix); prefix defaults to "sample".
echo "--- samples ---"
empty_bucket "sample-pipelines-artifacts-${account_id}"
delete_stack "$SAMPLES_STACK"

# --- Backend stack ---
echo "--- backend ---"
empty_bucket "${STACK}-data-${account_id}"
delete_stack "$STACK"

echo
if [[ "$CONFIRM" == yes ]]; then
  echo "Done. Remember: delete the Quick app + connector manually in the Quick"
  echo "console (see CONNECTOR_TEARDOWN.md). The packaging bucket is not removed."
else
  echo "Dry run only — nothing was deleted. Re-run with --yes to destroy."
fi
