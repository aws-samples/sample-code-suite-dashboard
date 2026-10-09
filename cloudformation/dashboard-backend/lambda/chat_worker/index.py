"""
Chat worker Lambda.

Invoked asynchronously by the stats Lambda (`POST /chat`) with:
  {
    "chatId": "<uuid>",
    "question": "why did this pipeline fail?",
    "pipelineContext": { ...pipeline row... },
    "userId": "<caller IAM user id>"
  }

Responsibilities:
  1. Confirm the configured AgentSpace exists (`GetAgentSpace`). If it does
     not, record a `devops_agent_not_configured` failure with a setup URL.
  2. `CreateChat` against the AgentSpace, then `SendMessage` with the user's
     question. SendMessage returns a streaming EventStream; we accumulate the
     content blocks until `responseCompleted` (or `responseFailed`).
  3. Write the final answer back to DynamoDB so the dashboard can poll
     `GET /chat/{chatId}`.

Errors are written to DynamoDB under `status=failed` so the UI can show them
without needing CloudWatch access.
"""
import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AGENT_SPACE_ID = os.environ.get('AGENT_SPACE_ID', '').strip()
CHAT_TABLE_NAME = os.environ['CHAT_TABLE_NAME']
SETUP_URL = os.environ.get('DEVOPS_AGENT_SETUP_URL', '')

ddb = boto3.client('dynamodb')
_devops_agent = None


def _agent_client():
    """boto3 client name is `devops-agent`; the IAM action prefix is
    `aidevops`. Created lazily so an old runtime boto3 that doesn't know the
    service surfaces as a chat error instead of an import-time crash."""
    global _devops_agent
    if _devops_agent is None:
        _devops_agent = boto3.client('devops-agent')
    return _devops_agent

# Cap the context we forward so a runaway payload can't become a runaway
# (billed) investigation. SendMessage content is limited to 32768 chars.
MAX_CONTEXT_CHARS = 20000
MAX_USER_ID_CHARS = 128


def _put_status(chat_id, status, extra=None):
    """UpdateItem writing the status plus optional string fields."""
    expr_names = {'#s': 'status'}
    expr_values = {':s': {'S': status}}
    update_parts = ['#s = :s']
    for i, (k, v) in enumerate((extra or {}).items()):
        if v is None:
            continue
        expr_names[f'#f{i}'] = k
        expr_values[f':v{i}'] = {'S': str(v)[:8000]}
        update_parts.append(f'#f{i} = :v{i}')
    ddb.update_item(
        TableName=CHAT_TABLE_NAME,
        Key={'chatId': {'S': chat_id}},
        UpdateExpression='SET ' + ', '.join(update_parts),
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )


def _not_configured(chat_id, message):
    _put_status(chat_id, 'failed', {
        'error': 'devops_agent_not_configured',
        'message': message,
        'setupUrl': SETUP_URL,
    })
    return {'ok': False, 'error': 'devops_agent_not_configured'}


def _build_user_message(question, pipeline_context):
    try:
        context_str = json.dumps(pipeline_context, default=str)
    except Exception:
        context_str = '{}'
    if len(context_str) > MAX_CONTEXT_CHARS:
        context_str = context_str[:MAX_CONTEXT_CHARS] + '\n...[truncated]'
    return (
        "You are investigating a specific CodePipeline execution. Base your "
        "answer on the pipeline context below and any additional data you can "
        "pull via your registered AWS association.\n\n"
        f"Pipeline context (JSON):\n{context_str}\n\n"
        f"User question:\n{question}"
    )


def _consume_stream(response):
    """Walk the SendMessage EventStream and assemble the final text.

    Returns (final_text, error_message); exactly one is None. Stream-level
    errors are captured rather than raised so the caller can persist them.
    """
    events = response.get('events')
    if events is None:
        return None, 'no_event_stream'

    # A response has several content blocks (the answer plus titles, reasoning
    # and tool traces). Track them by index and pick the answer at the end
    # instead of concatenating everything.
    blocks = {}  # index -> {'type': str|None, 'text': str}
    error = None
    start = time.time()

    for event in events:
        if 'contentBlockStart' in event:
            b = event['contentBlockStart']
            idx = b.get('index')
            if idx is not None:
                blocks.setdefault(idx, {'type': b.get('type'), 'text': ''})
                blocks[idx]['type'] = b.get('type') or blocks[idx].get('type')
        elif 'contentBlockDelta' in event:
            b = event['contentBlockDelta']
            idx = b.get('index')
            text_delta = ((b.get('delta') or {}).get('textDelta') or {}).get('text')
            if idx is not None and text_delta:
                blocks.setdefault(idx, {'type': None, 'text': ''})
                blocks[idx]['text'] += text_delta
        elif 'contentBlockStop' in event:
            # Some blocks deliver the full text here without any deltas.
            b = event['contentBlockStop']
            idx = b.get('index')
            if idx is not None and b.get('text'):
                blocks.setdefault(idx, {'type': b.get('type'), 'text': ''})
                if not blocks[idx]['text']:
                    blocks[idx]['text'] = b['text']
        elif 'responseCompleted' in event:
            break
        elif 'responseFailed' in event:
            f = event['responseFailed']
            error = f.get('errorMessage') or f.get('errorCode') or 'response_failed'
            break
        # heartbeat / responseCreated / responseInProgress / summary: ignore

    logger.info(
        f'Consumed {len(blocks)} content blocks in {time.time() - start:.1f}s: '
        f'{[(i, b.get("type"), len(b.get("text", ""))) for i, b in sorted(blocks.items())]}'
    )
    if error:
        return None, error

    def _is_title(t):
        return t and '\n' not in t and len(t) < 60

    seen, uniq = set(), []
    for _, b in sorted(blocks.items()):
        t = b.get('text')
        if not t or _is_title(t) or t.strip() in seen:
            continue
        seen.add(t.strip())
        uniq.append(t)
    answer = '\n\n'.join(uniq).strip()
    return (answer, None) if answer else (None, 'empty_response')


def handler(event, context):
    chat_id = event.get('chatId')
    question = (event.get('question') or '').strip()
    pipeline_context = event.get('pipelineContext') or {}
    user_id = (event.get('userId') or 'codesuite-dashboard')[:MAX_USER_ID_CHARS]

    if not chat_id or not question:
        logger.error('Missing chatId or question in event')
        return {'ok': False, 'error': 'invalid_event'}

    if not AGENT_SPACE_ID:
        return _not_configured(chat_id, 'No DevOps Agent AgentSpace is configured for this dashboard.')

    try:
        devops_agent = _agent_client()
    except Exception as e:
        logger.exception('Could not create devops-agent client')
        _put_status(chat_id, 'failed', {
            'error': 'devops_agent_sdk_unavailable',
            'message': f'boto3 {boto3.__version__} in this Lambda runtime does not support DevOps Agent: {str(e)[:200]}',
        })
        return {'ok': False}

    # Fail fast with a setup link if the AgentSpace doesn't exist (wrong ID,
    # wrong region, or deleted) instead of a raw API error.
    try:
        devops_agent.get_agent_space(agentSpaceId=AGENT_SPACE_ID)
    except ClientError as e:
        code = e.response.get('Error', {}).get('Code', '')
        if code in ('ResourceNotFoundException', 'NotFoundException', 'ValidationException'):
            return _not_configured(
                chat_id,
                f'AgentSpace {AGENT_SPACE_ID} was not found in {os.environ.get("AWS_REGION", "this region")}.',
            )
        logger.exception('GetAgentSpace failed')
        _put_status(chat_id, 'failed', {'error': f'{code}: {str(e)[:400]}'})
        return {'ok': False}

    try:
        create_resp = devops_agent.create_chat(
            agentSpaceId=AGENT_SPACE_ID, userId=user_id, userType='IAM',
        )
        execution_id = create_resp.get('executionId')
        if not execution_id:
            _put_status(chat_id, 'failed', {'error': 'no_execution_id_returned'})
            return {'ok': False}
        send_resp = devops_agent.send_message(
            agentSpaceId=AGENT_SPACE_ID,
            executionId=execution_id,
            userId=user_id,
            content=_build_user_message(question, pipeline_context),
        )
    except Exception as e:
        logger.exception('DevOps Agent invocation failed')
        _put_status(chat_id, 'failed', {'error': str(e)[:500]})
        return {'ok': False}

    text, err = _consume_stream(send_resp)
    if err:
        _put_status(chat_id, 'failed', {'error': err})
        return {'ok': False}

    _put_status(chat_id, 'succeeded', {'answer': text, 'agentSpaceId': AGENT_SPACE_ID})
    return {'ok': True}
