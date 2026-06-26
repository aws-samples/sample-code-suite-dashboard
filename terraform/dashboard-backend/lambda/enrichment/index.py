import json
import os
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
codepipeline = boto3.client('codepipeline')
codebuild = boto3.client('codebuild')
BUCKET = os.environ['BUCKET_NAME']
HOSTING_BUCKET = os.environ.get('HOSTING_BUCKET', '')


def get_deployed_version():
    """Read the current deployed version from the hosting bucket's version.json."""
    if not HOSTING_BUCKET:
        return 'unknown'
    try:
        resp = s3.get_object(Bucket=HOSTING_BUCKET, Key='version.json')
        data = json.loads(resp['Body'].read())
        return f"v{data.get('version', '?')}"
    except Exception:
        return 'unknown'


def handler(event, context):
    detail_type = event.get('detail-type', '')
    if detail_type == 'CodePipeline Pipeline Execution State Change':
        return enrich_pipeline_event(event)
    elif detail_type == 'CodeBuild Build State Change':
        return enrich_build_event(event)
    else:
        logger.warning(f"Unrecognized detail-type: {detail_type}")
        return {'statusCode': 200, 'body': 'skipped'}


def enrich_pipeline_event(event):
    detail = event['detail']
    pipeline_name = detail['pipeline']
    execution_id = detail['execution-id']
    state = detail['state']
    logger.info(f"Enriching pipeline event: {pipeline_name}/{execution_id} state={state}")
    if state not in ('SUCCEEDED', 'FAILED', 'CANCELED', 'SUPERSEDED'):
        logger.info(f"Skipping non-terminal state: {state}")
        return {'statusCode': 200, 'body': 'skipped non-terminal'}
    try:
        exec_resp = codepipeline.get_pipeline_execution(
            pipelineName=pipeline_name, pipelineExecutionId=execution_id)
        pe = exec_resp['pipelineExecution']
        trigger_type = pe.get('trigger', {}).get('triggerType', 'Unknown')
        revisions = pe.get('artifactRevisions', [])
        source_revision = revisions[0].get('revisionSummary', '') if revisions else ''
        deployed_version = get_deployed_version()
        actions_resp = codepipeline.list_action_executions(
            pipelineName=pipeline_name,
            filter={'pipelineExecutionId': execution_id})
        actions = actions_resp.get('actionExecutionDetails', [])
        stages = {}
        for a in actions:
            sn = a.get('stageName', '')
            if sn not in stages:
                stages[sn] = {'stage_name': sn, 'status': a.get('status', ''),
                    'start_time': str(a.get('startTime', '')),
                    'end_time': str(a.get('lastUpdateTime', '')),
                    'failure_reason': None}
            if a.get('status') == 'Failed':
                stages[sn]['status'] = 'Failed'
                stages[sn]['failure_reason'] = a.get('output', {}).get('executionResult', {}).get('externalExecutionSummary', '')
        start_time = str(pe.get('startTime', ''))
        end_time = str(pe.get('lastUpdateTime', event['time']))
        try:
            st = pe.get('startTime')
            et = pe.get('lastUpdateTime')
            duration = int((et - st).total_seconds()) if st and et else 0
        except Exception:
            duration = 0
        record = {
            'pipeline_name': pipeline_name, 'execution_id': execution_id,
            'execution_status': state, 'trigger_type': trigger_type,
            'source_revision': source_revision, 'deployed_version': deployed_version,
            'execution_start_time': start_time,
            'execution_end_time': end_time, 'total_duration_seconds': duration,
            'is_deployment': state in ('SUCCEEDED', 'FAILED'),
            'stages': list(stages.values()),
            'enriched_at': datetime.now(timezone.utc).isoformat()}
        now = datetime.now(timezone.utc)
        key = f"enriched/pipeline-executions/year={now.year}/month={now.month:02d}/day={now.day:02d}/{execution_id}.json"
        s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(record), ContentType='application/json')
        logger.info(f"Wrote enriched pipeline record: {key}")
        return {'statusCode': 200, 'body': 'success'}
    except Exception as e:
        logger.error(f"Failed to enrich pipeline event {execution_id}: {str(e)}")
        return {'statusCode': 200, 'body': 'skipped due to error'}


def enrich_build_event(event):
    detail = event['detail']
    build_status = detail.get('build-status', '')
    build_id = detail.get('build-id', '')
    project_name = detail.get('project-name', '')
    logger.info(f"Enriching build event: {project_name}/{build_id} status={build_status}")
    if build_status not in ('SUCCEEDED', 'FAILED', 'STOPPED'):
        logger.info(f"Skipping non-terminal build status: {build_status}")
        return {'statusCode': 200, 'body': 'skipped non-terminal'}
    try:
        resp = codebuild.batch_get_builds(ids=[build_id])
        builds = resp.get('builds', [])
        if not builds:
            logger.warning(f"No build found for {build_id}")
            return {'statusCode': 200, 'body': 'no build found'}
        b = builds[0]
        start = b.get('startTime')
        end = b.get('endTime')
        duration = int((end - start).total_seconds()) if start and end else 0
        phases = []
        for p in b.get('phases', []):
            ctx = p.get('contexts', [{}])
            msg = ctx[0].get('message', '') if ctx else ''
            phases.append({
                'phase_name': p.get('phaseType', ''),
                'duration_seconds': p.get('durationInSeconds', 0),
                'status': p.get('phaseStatus', ''),
                'context_message': msg if msg else None})
        record = {
            'project_name': project_name, 'build_id': build_id,
            'build_status': build_status, 'build_duration_seconds': duration,
            'initiator': b.get('initiator', ''),
            'source_version': b.get('sourceVersion', ''),
            'phases': phases,
            'enriched_at': datetime.now(timezone.utc).isoformat()}
        now = datetime.now(timezone.utc)
        short_id = build_id.split(':')[-1] if ':' in build_id else build_id
        key = f"enriched/build-details/year={now.year}/month={now.month:02d}/day={now.day:02d}/{short_id}.json"
        s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(record), ContentType='application/json')
        logger.info(f"Wrote enriched build record: {key}")
        return {'statusCode': 200, 'body': 'success'}
    except Exception as e:
        logger.error(f"Failed to enrich build event {build_id}: {str(e)}")
        return {'statusCode': 200, 'body': 'skipped due to error'}
