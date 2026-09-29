#!/usr/bin/env python3
"""Render import-ready Amazon Quick connector artifacts from a live stack.

Queries the deployed CloudFormation stack's connector outputs (read-only) and
fills in:
  - connector/openapi.json            -> connector/openapi.generated.json
  - connector/QUICK_APP_PROMPT.template.md -> connector/QUICK_APP_PROMPT.generated.md

The generated files contain account-specific values and are gitignored; the
templates stay portable in version control.

Uses the standard AWS credential chain (AWS_PROFILE / env vars / default
profile). --profile and --region are optional overrides.

Usage:
  python3 scripts/render_quick_app.py
  python3 scripts/render_quick_app.py --region us-west-2 --stack-name pipeline-dashboard
  AWS_PROFILE=my-profile python3 scripts/render_quick_app.py

Only performs read-only AWS calls (cloudformation describe-stacks) plus local
file writes. Nothing is deployed or mutated.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

CONNECTOR_DIR = Path(__file__).resolve().parent.parent / "cloudformation" / "dashboard-backend" / "connector"
OPENAPI_TEMPLATE = CONNECTOR_DIR / "openapi.json"
OPENAPI_OUT = CONNECTOR_DIR / "openapi.generated.json"
PROMPT_TEMPLATE = CONNECTOR_DIR / "QUICK_APP_PROMPT.template.md"
PROMPT_OUT = CONNECTOR_DIR / "QUICK_APP_PROMPT.generated.md"

# Stack outputs we require to render (fail clearly if the connector wasn't deployed).
REQUIRED_OUTPUTS = ["ConnectorTokenUrl", "ConnectorClientId", "ConnectorScope", "ConnectorBaseUrl"]


def fetch_outputs(stack_name, region, profile):
    """Return {OutputKey: OutputValue} for the stack. Read-only."""
    cmd = [
        "aws", "cloudformation", "describe-stacks",
        "--stack-name", stack_name,
        "--region", region,
        "--query", "Stacks[0].Outputs",
        "--output", "json",
    ]
    if profile:
        cmd += ["--profile", profile]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as e:
        sys.exit(f"ERROR: describe-stacks failed:\n{e.stderr.strip()}")
    except FileNotFoundError:
        sys.exit("ERROR: the AWS CLI ('aws') was not found on PATH.")
    outputs = json.loads(raw) or []
    return {o["OutputKey"]: o["OutputValue"] for o in outputs}


def require(outputs, stack_name):
    missing = [k for k in REQUIRED_OUTPUTS if k not in outputs]
    if missing:
        sys.exit(
            "ERROR: stack '{}' is missing connector outputs: {}.\n"
            "Deploy with -ConnectorAuthDomainPrefix set so the connector "
            "resources are created.".format(stack_name, ", ".join(missing))
        )


def derive(outputs):
    """Pull the API id, region, and Cognito domain prefix out of the URLs."""
    base = outputs["ConnectorBaseUrl"]          # https://<api>.execute-api.<region>.amazonaws.com/connector
    token = outputs["ConnectorTokenUrl"]        # https://<prefix>.auth.<region>.amazoncognito.com/oauth2/token
    host = base.split("://", 1)[1].split("/", 1)[0]
    api_id = host.split(".")[0]
    region = host.split(".execute-api.", 1)[1].split(".")[0]
    domain_prefix = token.split("://", 1)[1].split(".auth.", 1)[0]
    return api_id, region, domain_prefix


def render_openapi(api_id, region, domain_prefix):
    text = OPENAPI_TEMPLATE.read_text()
    rendered = (
        text.replace("REPLACE_API_ID", api_id)
            .replace("REPLACE_DOMAIN_PREFIX", domain_prefix)
            .replace("REPLACE_REGION", region)
    )
    # Validate it's still well-formed JSON and no placeholders remain.
    try:
        json.loads(rendered)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: rendered OpenAPI is not valid JSON: {e}")
    if "REPLACE_" in rendered:
        leftover = [tok for tok in ("REPLACE_API_ID", "REPLACE_REGION", "REPLACE_DOMAIN_PREFIX") if tok in rendered]
        sys.exit(f"ERROR: unfilled placeholders remain in OpenAPI: {leftover}")
    OPENAPI_OUT.write_text(rendered)


def render_prompt(outputs, region, account_id, stack_name):
    text = PROMPT_TEMPLATE.read_text()
    mapping = {
        "{{CONNECTOR_TOKEN_URL}}": outputs["ConnectorTokenUrl"],
        "{{CONNECTOR_CLIENT_ID}}": outputs["ConnectorClientId"],
        "{{CONNECTOR_SCOPE}}": outputs["ConnectorScope"],
        "{{CONNECTOR_BASE_URL}}": outputs["ConnectorBaseUrl"],
        "{{STACK_NAME}}": stack_name,
        "{{REGION}}": region,
        "{{ACCOUNT_ID}}": account_id or "unknown",
    }
    for k, v in mapping.items():
        text = text.replace(k, v)
    if "{{" in text:
        sys.exit("ERROR: unfilled {{...}} placeholders remain in the prompt.")
    PROMPT_OUT.write_text(text)


def account_from_arn(profile, region):
    cmd = ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text", "--region", region]
    if profile:
        cmd += ["--profile", profile]
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return None


def resolve_region(explicit, profile):
    """Region precedence: --region, then AWS_REGION / AWS_DEFAULT_REGION, then
    the region configured for the active profile. Errors if none is set."""
    import os
    if explicit:
        return explicit
    env = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if env:
        return env
    cmd = ["aws", "configure", "get", "region"]
    if profile:
        cmd += ["--profile", profile]
    try:
        r = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
        if r:
            return r
    except Exception:
        pass
    sys.exit("ERROR: no region found. Pass --region, or set AWS_REGION / your "
             "profile's region via `aws configure`.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stack-name", default="pipeline-dashboard")
    ap.add_argument("--region", default=None, help="Override region (default: AWS credential chain).")
    ap.add_argument("--profile", default=None, help="Override profile (default: AWS credential chain).")
    args = ap.parse_args()

    region = resolve_region(args.region, args.profile)
    outputs = fetch_outputs(args.stack_name, region, args.profile)
    require(outputs, args.stack_name)
    api_id, region, domain_prefix = derive(outputs)
    account_id = account_from_arn(args.profile, region)

    render_openapi(api_id, region, domain_prefix)
    render_prompt(outputs, region, account_id, args.stack_name)

    print("Rendered connector artifacts:")
    print(f"  {OPENAPI_OUT.relative_to(Path.cwd()) if OPENAPI_OUT.is_relative_to(Path.cwd()) else OPENAPI_OUT}")
    print(f"  {PROMPT_OUT.relative_to(Path.cwd()) if PROMPT_OUT.is_relative_to(Path.cwd()) else PROMPT_OUT}")
    print()
    print(f"  API id:        {api_id}")
    print(f"  Region:        {region}")
    print(f"  Cognito domain:{domain_prefix}")
    print(f"  Client id:     {outputs['ConnectorClientId']}")
    print()
    print("Next: import openapi.generated.json into the Quick console, then follow")
    print("QUICK_APP_PROMPT.generated.md. Fetch the client secret from Cognito (not stored in repo).")


if __name__ == "__main__":
    main()
