import base64
import copy
import json
import os
import time
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

athena = boto3.client('athena')
codepipeline = boto3.client('codepipeline')  # local-account client (default)
s3 = boto3.client('s3')
sts = boto3.client('sts')
organizations = boto3.client('organizations')
bedrock_runtime = boto3.client('bedrock-runtime')
DATABASE = os.environ['DATABASE']
WORKGROUP = os.environ['WORKGROUP']
ACCOUNT_ID = os.environ['ACCOUNT_ID']
REGION = os.environ['REGION']
HOSTING_BUCKET = os.environ.get('HOSTING_BUCKET', '')
# CORS allow-origin echoed in every response. The dashboard talks to this
# API exclusively through the local Vite dev-server proxy (which signs with
# SigV4), so the browser never makes direct cross-origin calls. We still
# echo a sensible default for operators who want to debug from a browser.
CORS_ALLOW_ORIGIN = os.environ.get('CORS_ALLOW_ORIGIN', 'http://localhost:5173')

# Real cross-account entries, each with a role_arn the Lambda can assume.
# JSON-encoded list of {account_id, alias, region, role_arn, synthetic}.
try:
    TRACKED_ACCOUNTS = json.loads(os.environ.get('TRACKED_ACCOUNTS', '[]'))
    if not isinstance(TRACKED_ACCOUNTS, list):
        TRACKED_ACCOUNTS = []
except Exception:
    TRACKED_ACCOUNTS = []

# Synthetic accounts are generated *inside* the Lambda so the env-var
# payload stays small (Lambda has a ~4 KB env-var limit). The dashboard
# clones the local account's pipelines under each synthetic account so the
# multi-account UI has volume to demo at scale.
try:
    SYNTHETIC_ACCOUNT_COUNT = int(os.environ.get('SYNTHETIC_ACCOUNT_COUNT', '0'))
except Exception:
    SYNTHETIC_ACCOUNT_COUNT = 0
SYNTHETIC_ALIASES = [s for s in os.environ.get(
    'SYNTHETIC_ALIASES',
    'prod,stage,dev,qa,preview,sandbox,data,platform,ml,ops,audit,shared-services,tools,security,logging',
).split(',') if s]
SYNTHETIC_REGIONS = [s for s in os.environ.get(
    'SYNTHETIC_REGIONS',
    'us-east-1,us-west-2,eu-west-1,eu-central-1,ap-southeast-2,ap-northeast-1',
).split(',') if s]

# Organizations auto-discovery. When ORG_ENABLED=true, the Lambda calls
# organizations:ListAccounts and treats every active account in the org
# (minus the local + excluded list) as an additional tracked account. The
# reader role is assumed to live in each account because the StackSet
# created it there.
BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'amazon.nova-pro-v1:0')

ORG_ENABLED = os.environ.get('ORG_ENABLED', 'false').lower() == 'true'
ORG_ROLE_NAME = os.environ.get('ORG_ROLE_NAME', 'PipelineDashboardReader')
ORG_REGIONS = [r for r in os.environ.get('ORG_REGIONS', '').split(',') if r] or [REGION]
ORG_EXCLUDE_ACCOUNTS = set(a for a in os.environ.get('ORG_EXCLUDE_ACCOUNTS', '').split(',') if a)
# Cache the org account list across invocations of the same warm container.
# AWS Organizations data changes rarely; refreshing every minute is plenty.
_org_account_cache = {'expires_at': 0, 'accounts': []}


def _list_organization_accounts():
    """Return [{account_id, alias, region, role_arn, synthetic=False}, ...]
    for every ACTIVE account in the org, expanded across the configured
    target regions. Cached for 60s. Returns [] on any failure so the dashboard
    keeps rendering local-account data if Organizations is unreachable."""
    if not ORG_ENABLED:
        return []
    now = time.time()
    if now < _org_account_cache['expires_at']:
        return _org_account_cache['accounts']
    out = []
    try:
        paginator = organizations.get_paginator('list_accounts')
        for page in paginator.paginate():
            for acct in page.get('Accounts', []):
                if acct.get('Status') != 'ACTIVE':
                    continue
                aid = acct['Id']
                if aid == ACCOUNT_ID:
                    continue  # skip the central account
                if aid in ORG_EXCLUDE_ACCOUNTS:
                    continue
                # Friendly alias = account name with whitespace squashed,
                # falling back to the 12-digit ID.
                alias = (acct.get('Name') or aid).strip().lower().replace(' ', '-')[:32] or aid
                role_arn = f"arn:aws:iam::{aid}:role/{ORG_ROLE_NAME}"
                for region in ORG_REGIONS:
                    out.append({
                        'account_id': aid,
                        'alias':      alias if len(ORG_REGIONS) == 1 else f"{alias}-{region}",
                        'region':     region,
                        'role_arn':   role_arn,
                        'synthetic':  False,
                    })
    except Exception as e:
        logger.warning(f"organizations:ListAccounts failed: {e}")
        out = []
    _org_account_cache['expires_at'] = now + 60
    _org_account_cache['accounts'] = out
    return out


def _generate_synthetic_accounts():
    """Generates a deterministic list of {account_id, alias, region,
    synthetic} entries for UI volume when SyntheticAccountCount > 0."""
    out = []
    n_aliases = max(1, len(SYNTHETIC_ALIASES))
    n_regions = max(1, len(SYNTHETIC_REGIONS))
    for i in range(SYNTHETIC_ACCOUNT_COUNT):
        wave = (i // n_aliases) + 1
        out.append({
            'account_id': f"{(100000000000 + i * 1234567 + 7):012d}",
            'alias':      f"{SYNTHETIC_ALIASES[i % n_aliases]}-{wave:02d}",
            'region':     SYNTHETIC_REGIONS[i % n_regions],
            'role_arn':   None,
            'synthetic':  True,
        })
    return out


# Effective list seen by handlers: real entries first, then org-discovered,
# then synthetic.
def _effective_tracked_accounts():
    return TRACKED_ACCOUNTS + _list_organization_accounts() + _generate_synthetic_accounts()

CORS = {
    'Access-Control-Allow-Origin': CORS_ALLOW_ORIGIN,
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
    # Include the SigV4 header set so a SigV4-aware browser client could call
    # the API directly during debugging.
    'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Amz-Date,X-Amz-Security-Token,X-Amz-Content-Sha256',
    'Content-Type': 'application/json'
}

STATUS_MAP = {
    'Succeeded': 'Succeeded', 'SUCCEEDED': 'Succeeded',
    'InProgress': 'InProgress', 'IN_PROGRESS': 'InProgress', 'STARTED': 'InProgress',
    'Failed': 'Failed', 'FAILED': 'Failed',
    'Stopped': 'Stopped', 'STOPPED': 'Stopped',
    'Cancelled': 'Stopped', 'CANCELED': 'Stopped',
    'Superseded': 'Stopped', 'SUPERSEDED': 'Stopped',
}


def normalize_status(s):
    if not s:
        return None
    return STATUS_MAP.get(s, s)


def to_ms(dt):
    if not dt:
        return None
    try:
        return int(dt.timestamp() * 1000)
    except Exception:
        return None


def get_deployed_version():
    if not HOSTING_BUCKET:
        return '—'
    try:
        resp = s3.get_object(Bucket=HOSTING_BUCKET, Key='version.json')
        data = json.loads(resp['Body'].read())
        v = data.get('version')
        return f'v{v}' if v is not None else '—'
    except Exception as e:
        logger.warning(f"Could not read deployed version: {e}")
        return '—'


# ============================================================
# Multi-account: assume cross-account roles + synthesize demo rows
# ============================================================
def _build_codepipeline_client(account):
    """Return a codepipeline boto3 client scoped to the target account/region.
    For the local account (no role_arn) returns the default client. For
    cross-account entries, calls sts:AssumeRole and constructs a session.
    Raises on credential failure so the caller can skip this account
    cleanly."""
    region = account.get('region') or REGION
    role_arn = account.get('role_arn')
    if not role_arn:
        # Local-account or same-account-different-region client.
        return boto3.client('codepipeline', region_name=region)
    resp = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName='pipeline-dashboard-reader',
        DurationSeconds=900,
    )
    creds = resp['Credentials']
    return boto3.client(
        'codepipeline',
        region_name=region,
        aws_access_key_id=creds['AccessKeyId'],
        aws_secret_access_key=creds['SecretAccessKey'],
        aws_session_token=creds['SessionToken'],
    )


def _synthesize_pipelines_for(account, base_rows, limit=3):
    """Clone the local-account rows under a tracked account so the UI can
    demo multi-account aggregation without real cross-account setup. Status
    distribution and durations are perturbed deterministically so each
    synthetic account looks distinct. Capped to `limit` clones per account
    so the dashboard doesn't render thousands of cards at scale."""
    if not base_rows:
        return []
    seed = sum(ord(c) for c in account['alias'])
    rotated = base_rows[seed % len(base_rows):] + base_rows[:seed % len(base_rows)]
    rows_to_clone = rotated[:limit]
    out = []
    statuses = ['Succeeded', 'Succeeded', 'Succeeded', 'InProgress', 'Failed', 'Stopped']
    for i, base in enumerate(rows_to_clone):
        clone = copy.deepcopy(base)
        clone['accountId']    = f"aws-{account['account_id']}"
        clone['accountAlias'] = account['alias']
        clone['region']       = account.get('region') or REGION
        # Perturb the headline status so the UI shows variety.
        clone['status'] = statuses[(seed + i) % len(statuses)]
        # Bump the last-run timestamp by a deterministic offset.
        if clone.get('lastRunStart'):
            clone['lastRunStart'] = int(clone['lastRunStart']) - ((seed + i) % 7) * 60_000
        # Adjust duration so the sparkline differs.
        clone['durationMs'] = int(clone.get('durationMs', 60_000)) + ((seed + i) % 5) * 10_000
        # Rebuild logsUrl to point at the synthetic account's region (the URL
        # won't actually resolve cross-account, but it makes the UI honest).
        if clone.get('logsUrl'):
            clone['logsUrl'] = clone['logsUrl'].replace(f'region={REGION}', f"region={clone['region']}")
        out.append(clone)
    return out


def run_query(sql):
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={'Database': DATABASE},
        WorkGroup=WORKGROUP
    )
    qid = resp['QueryExecutionId']
    for _ in range(30):
        status = athena.get_query_execution(QueryExecutionId=qid)['QueryExecution']['Status']['State']
        if status == 'SUCCEEDED':
            return athena.get_query_results(QueryExecutionId=qid)
        if status in ('FAILED', 'CANCELLED'):
            raise Exception(f"Athena query {status}")
        time.sleep(1)
    raise Exception("Athena query timeout")


def response(status, body):
    return {'statusCode': status, 'headers': CORS, 'body': json.dumps(body)}


def get_route(event):
    rk = event.get('routeKey') or ''
    if rk:
        parts = rk.split(' ', 1)
        if len(parts) == 2:
            return parts[1].rstrip('/') or '/'
    path = event.get('rawPath') or event.get('path') or '/'
    return path.rstrip('/') or '/'


def handle_stats(event):
    sql = """
    WITH recent AS (
      SELECT pipeline_name, execution_id, execution_status, enriched_at,
             ROW_NUMBER() OVER (PARTITION BY pipeline_name ORDER BY enriched_at DESC) as rn
      FROM enriched_pipeline_executions
    ),
    last_24h AS (
      SELECT execution_status
      FROM enriched_pipeline_executions
      WHERE from_iso8601_timestamp(enriched_at) > current_timestamp - interval '24' hour
    )
    SELECT
      (SELECT COUNT(DISTINCT pipeline_name) FROM enriched_pipeline_executions) AS total,
      (SELECT COUNT(*) FROM recent WHERE rn = 1 AND execution_status IN ('STARTED', 'IN_PROGRESS')) AS running,
      (SELECT COUNT(*) FROM last_24h WHERE execution_status = 'FAILED') AS failed_24h,
      (SELECT COUNT(*) FROM last_24h WHERE execution_status = 'SUCCEEDED') AS succeeded_24h,
      (SELECT COUNT(*) FROM last_24h) AS runs_24h
    """
    result = run_query(sql)
    rows = result['ResultSet']['Rows']
    if len(rows) < 2:
        raise Exception("No data rows returned")
    values = rows[1]['Data']
    total = int(values[0].get('VarCharValue', '0') or '0')
    running = int(values[1].get('VarCharValue', '0') or '0')
    failed_24h = int(values[2].get('VarCharValue', '0') or '0')
    succeeded_24h = int(values[3].get('VarCharValue', '0') or '0')
    runs_24h = int(values[4].get('VarCharValue', '0') or '0')
    success_rate = round((succeeded_24h / runs_24h) * 100) if runs_24h > 0 else 100
    return response(200, {
        'total': total, 'running': running, 'failed24h': failed_24h,
        'successRate': success_rate, 'runs24h': runs_24h
    })


def handle_accounts(event):
    accounts = [{
        'id': f'aws-{ACCOUNT_ID}',
        'alias': 'aws',
        'region': REGION,
    }]
    for a in _effective_tracked_accounts():
        accounts.append({
            'id': f"aws-{a['account_id']}",
            'alias': a['alias'],
            'region': a.get('region') or REGION,
        })
    return response(200, accounts)


def extract_source_meta(pipeline_def):
    repo, branch, trigger = '', '', 'BranchMerge'
    try:
        stages = pipeline_def.get('pipeline', {}).get('stages', [])
        if not stages:
            return repo, branch, trigger
        source_stage = stages[0]
        for action in source_stage.get('actions', []):
            cfg = action.get('configuration', {}) or {}
            provider = action.get('actionTypeId', {}).get('provider', '')
            if provider in ('CodeCommit',):
                repo = cfg.get('RepositoryName', '')
                branch = cfg.get('BranchName', '')
            elif provider in ('GitHub', 'CodeStarSourceConnection'):
                owner = cfg.get('Owner') or cfg.get('FullRepositoryId', '').split('/')[0] if cfg.get('FullRepositoryId') else ''
                name = cfg.get('Repo') or (cfg.get('FullRepositoryId', '').split('/', 1)[1] if '/' in cfg.get('FullRepositoryId', '') else cfg.get('FullRepositoryId', ''))
                repo = f"{owner}/{name}" if owner and name else (name or '')
                branch = cfg.get('BranchName') or cfg.get('Branch', '')
            elif provider == 'S3':
                repo = cfg.get('S3Bucket', '')
                branch = cfg.get('S3ObjectKey', '')
            if repo or branch:
                break
        if branch.startswith('refs/tags/') or branch.startswith('v'):
            trigger = 'GitTag'
    except Exception as e:
        logger.warning(f"Could not extract source meta: {e}")
    return repo, branch, trigger


def synthesize_source_url(pipeline_name, pipeline_def, stage_state):
    """Build a deep link for a Source stage when CodePipeline doesn't supply
    externalExecutionUrl (common for CodeCommit). Returns None if the stage is
    not a Source stage we know how to link to."""
    try:
        # Find the matching stage in the pipeline definition to read its config
        stage_name = stage_state.get('stageName')
        cfg_stages = pipeline_def.get('pipeline', {}).get('stages', [])
        cfg_stage = next((s for s in cfg_stages if s.get('name') == stage_name), None)
        if not cfg_stage:
            return None

        action_state = (stage_state.get('actionStates') or [{}])[0]
        action_cfg_stage = (cfg_stage.get('actions') or [{}])[0]
        cfg = action_cfg_stage.get('configuration', {}) or {}
        provider = action_cfg_stage.get('actionTypeId', {}).get('provider', '')

        # Latest commit SHA for this stage's last execution
        rev = action_state.get('currentRevision', {}) or {}
        commit = rev.get('revisionId', '')

        if provider == 'CodeCommit':
            repo = cfg.get('RepositoryName', '')
            if not repo:
                return None
            base = f'https://console.aws.amazon.com/codesuite/codecommit/repositories/{repo}'
            if commit:
                return f'{base}/commit/{commit}?region={REGION}'
            return f'{base}/browse?region={REGION}'

        if provider in ('GitHub', 'CodeStarSourceConnection'):
            full = cfg.get('FullRepositoryId', '')
            if full and commit:
                return f'https://github.com/{full}/commit/{commit}'
            if full:
                return f'https://github.com/{full}'
        return None
    except Exception:
        return None


def build_pipeline_row(pipeline_summary, deployed_version='—',
                       cp_client=None, account_id=None, alias=None, region=None):
    """Build a UI row for a single pipeline. Defaults to the local-account
    codepipeline client when cp_client is omitted, so existing call sites
    keep working."""
    cp = cp_client or codepipeline
    acct_id = account_id or ACCOUNT_ID
    acct_alias = alias or 'aws'
    acct_region = region or REGION

    name = pipeline_summary['name']
    try:
        pipeline_def = cp.get_pipeline(name=name)
        repo, branch, trigger = extract_source_meta(pipeline_def)

        state = cp.get_pipeline_state(name=name)
        stage_states = []
        overall = 'Succeeded'
        has_running = False
        has_failed = False
        has_stopped = False
        for s in state.get('stageStates', []):
            latest = s.get('latestExecution') or {}
            st = normalize_status(latest.get('status'))

            # Pull the deep link from the first action that has one. For Build
            # stages this is the CodeBuild build URL; for Source stages it's a
            # CodeCommit commit URL; for Deploy stages it's whatever the
            # provider supplies.
            stage_url = None
            for a in s.get('actionStates', []) or []:
                ax = a.get('latestExecution') or {}
                url = ax.get('externalExecutionUrl')
                if url:
                    stage_url = url
                    break

            # Source actions on CodeCommit don't populate externalExecutionUrl.
            # Synthesize a deep link to the commit from the action config and
            # currentRevision.
            if not stage_url:
                stage_url = synthesize_source_url(name, pipeline_def, s)

            stage_states.append({
                'name': s.get('stageName', ''),
                'status': st,
                'url': stage_url,
            })
            if st == 'InProgress':
                has_running = True
            elif st == 'Failed':
                has_failed = True
            elif st == 'Stopped':
                has_stopped = True
        if has_running:
            overall = 'InProgress'
        elif has_failed:
            overall = 'Failed'
        elif has_stopped and not any(s['status'] == 'Succeeded' for s in stage_states):
            overall = 'Stopped'

        execs_resp = cp.list_pipeline_executions(pipelineName=name, maxResults=10)
        summaries = execs_resp.get('pipelineExecutionSummaries', [])

        version = deployed_version
        if version == '—' and summaries:
            revs = summaries[0].get('sourceRevisions') or []
            if revs:
                rev_id = revs[0].get('revisionId', '')
                rev_summary = revs[0].get('revisionSummary') or ''
                if rev_summary and '\n' not in rev_summary and len(rev_summary) < 40:
                    version = rev_summary
                elif rev_id:
                    version = rev_id[:8]
                else:
                    version = '—'

        history = []
        for e in summaries:
            st_ms = to_ms(e.get('startTime'))
            end_ms = to_ms(e.get('lastUpdateTime'))
            duration_ms = (end_ms - st_ms) if (st_ms and end_ms) else 0
            history.append({
                'status': normalize_status(e.get('status')),
                'durationMs': duration_ms,
                'startTime': st_ms,
            })
        history = list(reversed(history))

        if summaries:
            latest_exec = summaries[0]
            last_run_start = to_ms(latest_exec.get('startTime')) or to_ms(latest_exec.get('lastUpdateTime')) or 0
            last_end = to_ms(latest_exec.get('lastUpdateTime')) or 0
            duration_ms = (last_end - last_run_start) if (last_run_start and last_end) else 0
            trigger_meta = (latest_exec.get('trigger') or {}).get('triggerType') or trigger
        else:
            last_run_start = 0
            duration_ms = 0
            trigger_meta = trigger

        trigger_norm = {
            'Webhook': 'BranchMerge', 'CloudWatchEvent': 'BranchMerge',
            'PollForSourceChanges': 'BranchMerge', 'PutActionRevision': 'Manual',
            'StartPipelineExecution': 'Manual', 'CreatePipeline': 'Manual',
        }.get(trigger_meta, trigger_meta if trigger_meta in ('GitTag', 'BranchMerge', 'Manual', 'Schedule') else 'BranchMerge')

        return {
            'name': name,
            'accountId': f'aws-{acct_id}',
            'accountAlias': acct_alias,
            'region': acct_region,
            'repository': repo or '—',
            'branch': branch or 'main',
            'triggerType': trigger_norm,
            'status': overall,
            'stages': stage_states,
            'version': version,
            'lastRunStart': last_run_start,
            'durationMs': duration_ms,
            'history': history,
            'logsUrl': f'https://console.aws.amazon.com/codesuite/codepipeline/pipelines/{name}/view?region={acct_region}',
        }
    except Exception as e:
        logger.error(f"Failed to build row for {name}: {e}")
        return None


def _list_pipelines_for_account(cp_client):
    out = []
    paginator = cp_client.get_paginator('list_pipelines')
    for page in paginator.paginate():
        out.extend(page.get('pipelines', []))
    return out


def handle_pipelines(event):
    rows, errors = _collect_all_pipeline_rows()
    return response(200, {'pipelines': rows, 'errors': errors})


def _collect_all_pipeline_rows():
    """Assemble full pipeline rows across the local account, tracked accounts,
    org-discovered accounts, and synthetic accounts. Returns (rows, errors).
    Shared by the legacy /pipelines handler and the connector handlers."""
    deployed_version = get_deployed_version()
    rows = []
    errors = []

    # 1) Local account (always queried).
    try:
        for p in _list_pipelines_for_account(codepipeline):
            row = build_pipeline_row(p, deployed_version=deployed_version)
            if row:
                rows.append(row)
    except Exception as e:
        logger.error(f"Local account listing failed: {e}")
        errors.append({'accountId': f'aws-{ACCOUNT_ID}', 'error': 'listing_failed'})

    # 2) Tracked accounts. Synthetic entries clone local rows; real entries
    #    assume the configured cross-account role and query their pipelines.
    base_for_synthesis = list(rows)  # snapshot before we add tracked rows
    for account in _effective_tracked_accounts():
        if account.get('synthetic'):
            rows.extend(_synthesize_pipelines_for(account, base_for_synthesis))
            continue
        try:
            cp_client = _build_codepipeline_client(account)
            for p in _list_pipelines_for_account(cp_client):
                row = build_pipeline_row(
                    p,
                    deployed_version='—',  # tracked accounts don't share the central hosting bucket
                    cp_client=cp_client,
                    account_id=account['account_id'],
                    alias=account['alias'],
                    region=account.get('region') or REGION,
                )
                if row:
                    rows.append(row)
        except Exception as e:
            logger.error(f"Tracked account {account.get('alias')} ({account.get('account_id')}) failed: {e}")
            # Don't echo raw boto3 exception text back to the client — it leaks
            # role ARNs, account IDs, and internal trace details. Log it,
            # return a short code.
            errors.append({
                'accountId': f"aws-{account.get('account_id')}",
                'alias': account.get('alias'),
                'error': 'unreachable',
            })

    return rows, errors


# ============================================================
# Connector handlers (JWT-authorized /connector/* routes)
# ------------------------------------------------------------
# Flat, paginated responses for the Amazon Quick OpenAPI connector, which
# cannot consume the nested arrays the legacy /pipelines route returns.
# See cloudformation/dashboard-backend/CONNECTOR_ROUTE_CONTRACT.md.
# ============================================================
CONNECTOR_DEFAULT_PAGE_SIZE = 25
CONNECTOR_MAX_PAGE_SIZE = 100
CONNECTOR_VALID_STATUSES = ('Succeeded', 'InProgress', 'Failed', 'Stopped')


def _qs(event, name, default=None):
    return (event.get('queryStringParameters') or {}).get(name, default)


def _parse_page_size(event):
    raw = _qs(event, 'pageSize')
    if raw is None or raw == '':
        return CONNECTOR_DEFAULT_PAGE_SIZE
    try:
        n = int(raw)
    except (TypeError, ValueError):
        raise ValueError('invalid_page_size')
    if n < 1 or n > CONNECTOR_MAX_PAGE_SIZE:
        raise ValueError('invalid_page_size')
    return n


def _decode_offset(next_token):
    if not next_token:
        return 0
    try:
        decoded = json.loads(base64.urlsafe_b64decode(next_token.encode('utf-8')).decode('utf-8'))
        offset = int(decoded.get('o', 0))
        if offset < 0:
            raise ValueError
        return offset
    except Exception:
        raise ValueError('invalid_next_token')


def _encode_offset(offset):
    return base64.urlsafe_b64encode(json.dumps({'o': offset}).encode('utf-8')).decode('utf-8')


def _paginate(items, offset, page_size):
    page = items[offset:offset + page_size]
    next_offset = offset + page_size
    next_token = _encode_offset(next_offset) if next_offset < len(items) else ''
    return page, next_token


def _flat_summary(row):
    """Project a full pipeline row down to a single-level summary object."""
    return {
        'accountId': row.get('accountId', ''),
        'accountAlias': row.get('accountAlias', ''),
        'region': row.get('region', ''),
        'name': row.get('name', ''),
        'repository': row.get('repository', '—'),
        'branch': row.get('branch', 'main'),
        'triggerType': row.get('triggerType', 'BranchMerge'),
        'status': row.get('status', 'Stopped'),
        'version': row.get('version', '—'),
        'lastRunStart': int(row.get('lastRunStart') or 0),
        'durationMs': int(row.get('durationMs') or 0),
        'stageCount': len(row.get('stages') or []),
        'logsUrl': row.get('logsUrl', ''),
    }


def handle_connector_stats(event):
    # Identical payload to handle_stats; kept as its own entry point so the
    # connector contract is explicit and can diverge later without touching
    # the legacy route.
    return handle_stats(event)


def handle_connector_accounts(event):
    try:
        page_size = _parse_page_size(event)
        offset = _decode_offset(_qs(event, 'nextToken'))
    except ValueError as ve:
        return response(400, {'error': str(ve)})

    accounts = [{
        'id': f'aws-{ACCOUNT_ID}',
        'alias': 'aws',
        'region': REGION,
    }]
    for a in _effective_tracked_accounts():
        accounts.append({
            'id': f"aws-{a['account_id']}",
            'alias': a['alias'],
            'region': a.get('region') or REGION,
        })

    page, next_token = _paginate(accounts, offset, page_size)
    return response(200, {'items': page, 'nextToken': next_token})


def handle_connector_pipelines(event):
    try:
        page_size = _parse_page_size(event)
        offset = _decode_offset(_qs(event, 'nextToken'))
    except ValueError as ve:
        return response(400, {'error': str(ve)})

    status_filter = _qs(event, 'status')
    if status_filter is not None and status_filter != '' and status_filter not in CONNECTOR_VALID_STATUSES:
        return response(400, {'error': 'invalid_status'})
    account_filter = _qs(event, 'accountId')

    rows, errors = _collect_all_pipeline_rows()

    filtered = rows
    if account_filter:
        filtered = [r for r in filtered if r.get('accountId') == account_filter]
    if status_filter:
        filtered = [r for r in filtered if r.get('status') == status_filter]

    summaries = [_flat_summary(r) for r in filtered]
    page, next_token = _paginate(summaries, offset, page_size)
    return response(200, {
        'items': page,
        'nextToken': next_token,
        'errorCount': len(errors),
    })


def handle_connector_pipeline_detail(event):
    params = event.get('pathParameters') or {}
    account_id = params.get('accountId', '')
    pipeline_name = params.get('pipelineName', '')
    if not account_id or not pipeline_name:
        return response(404, {'error': 'pipeline_not_found'})

    rows, _ = _collect_all_pipeline_rows()
    match = next(
        (r for r in rows if r.get('accountId') == account_id and r.get('name') == pipeline_name),
        None,
    )
    if not match:
        return response(404, {'error': 'pipeline_not_found'})

    detail = _flat_summary(match)
    detail.pop('stageCount', None)
    detail['stages'] = [
        {'name': s.get('name', ''), 'status': s.get('status') or 'Stopped', 'url': s.get('url') or ''}
        for s in (match.get('stages') or [])
    ]
    detail['history'] = [
        {
            'status': h.get('status') or 'Stopped',
            'durationMs': int(h.get('durationMs') or 0),
            'startTime': int(h.get('startTime') or 0),
        }
        for h in (match.get('history') or [])
    ]
    return response(200, detail)


CHAT_SYSTEM_PROMPT = (
    "You are a helpful AI assistant embedded in a CodePipeline observability "
    "dashboard. The user is looking at one specific pipeline execution and "
    "wants to understand what is happening.\n\n"
    "Answer based ONLY on the pipeline context provided in the user message. "
    "Be concise, specific, and actionable. Prefer short paragraphs over long "
    "walls of text. If the context does not contain enough information to "
    "answer, say so plainly and point them to the specific AWS console page "
    "or CloudWatch log group that would.\n\n"
    "Do not fabricate stage names, error messages, resource IDs, or timestamps."
)

CHAT_MAX_QUESTION_CHARS = 2000
CHAT_MAX_CONTEXT_CHARS = 20000
CHAT_MAX_OUTPUT_TOKENS = 800


def handle_chat(event):
    raw_body = event.get('body') or '{}'
    # API Gateway HTTP API sometimes ships the body base64-encoded.
    if event.get('isBase64Encoded'):
        import base64
        try:
            raw_body = base64.b64decode(raw_body).decode('utf-8')
        except Exception:
            return response(400, {'error': 'invalid_body_encoding'})
    try:
        body = json.loads(raw_body)
    except Exception:
        return response(400, {'error': 'invalid_json'})

    question = (body.get('question') or '').strip()
    pipeline_context = body.get('pipelineContext') or {}

    if not question:
        return response(400, {'error': 'question_required'})
    if len(question) > CHAT_MAX_QUESTION_CHARS:
        return response(400, {'error': 'question_too_long', 'maxChars': CHAT_MAX_QUESTION_CHARS})

    try:
        context_str = json.dumps(pipeline_context, default=str)
    except Exception:
        return response(400, {'error': 'invalid_pipeline_context'})
    if len(context_str) > CHAT_MAX_CONTEXT_CHARS:
        context_str = context_str[:CHAT_MAX_CONTEXT_CHARS] + '\n...[truncated]'

    user_message = (
        f"Pipeline context (JSON):\n{context_str}\n\n"
        f"Question:\n{question}"
    )

    try:
        resp = bedrock_runtime.converse(
            modelId=BEDROCK_MODEL_ID,
            system=[{'text': CHAT_SYSTEM_PROMPT}],
            messages=[{'role': 'user', 'content': [{'text': user_message}]}],
            inferenceConfig={'maxTokens': CHAT_MAX_OUTPUT_TOKENS, 'temperature': 0.2},
        )
    except Exception as e:
        logger.exception('Bedrock converse failed')
        return response(502, {'error': 'bedrock_error', 'message': str(e)[:200]})

    try:
        answer = resp['output']['message']['content'][0]['text']
    except (KeyError, IndexError, TypeError):
        return response(502, {'error': 'bedrock_empty_response'})

    usage = resp.get('usage') or {}
    return response(200, {
        'answer': answer,
        'modelId': BEDROCK_MODEL_ID,
        'usage': {
            'inputTokens': usage.get('inputTokens'),
            'outputTokens': usage.get('outputTokens'),
        },
    })


def handler(event, context):
    method = (event.get('requestContext', {}).get('http', {}) or {}).get('method', 'GET')
    if method == 'OPTIONS':
        return response(200, {})
    # Authorization is enforced by API Gateway (AWS_IAM). Any request
    # reaching this handler has already been authenticated and authorised
    # via SigV4 + an attached execute-api:Invoke policy.
    try:
        route = get_route(event)
        route_key = event.get('routeKey') or ''
        logger.info(f"Routing request: {method} {route} (routeKey={route_key})")

        # Connector routes (JWT-authorized). The pipeline-detail route carries
        # path parameters, so match it on the raw routeKey template rather than
        # the resolved path.
        if route_key == 'GET /connector/pipelines/{accountId}/{pipelineName}':
            return handle_connector_pipeline_detail(event)
        if route == '/connector/stats':
            return handle_connector_stats(event)
        if route == '/connector/accounts':
            return handle_connector_accounts(event)
        if route == '/connector/pipelines':
            return handle_connector_pipelines(event)

        # Legacy AWS_IAM routes (local Vite/React UI).
        if route in ('/stats', '/'):
            return handle_stats(event)
        if route == '/accounts':
            return handle_accounts(event)
        if route == '/pipelines':
            return handle_pipelines(event)
        if route == '/chat' and method == 'POST':
            return handle_chat(event)
        return response(404, {'error': 'not_found'})
    except Exception as e:
        # Log the full exception, return a generic message + request id so the
        # caller can correlate without leaking internal detail.
        logger.exception("Handler failed")
        request_id = getattr(context, 'aws_request_id', 'unknown')
        return response(500, {'error': 'internal_error', 'requestId': request_id})
