"""
Chat worker Lambda.

Invoked asynchronously from the stats Lambda (`POST /chat`) with:
  {
    "chatId": "<uuid>",
    "question": "why did this pipeline fail?",
    "pipelineContext": { ...pipeline row... }
  }

Responsibilities:
  1. Call `devops-agent:CreateChat` to spin up a new execution against the
     configured AgentSpace.
  2. Call `devops-agent:SendMessage` with the user's question. The API
     returns a streaming EventStream — we accumulate `contentBlockDelta`
     text deltas until we see `responseCompleted` (or `responseFailed`).
  3. Write the final answer back to DynamoDB so the dashboard can poll
     `GET /chat/{chatId}` and pick it up.

Errors are captured to DynamoDB under `status=failed` so the UI can display
them without needing CloudWatch access.
"""
import json
import logging
import os
import time
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AGENT_SPACE_ID = os.environ['AGENT_SPACE_ID']
CHAT_TABLE_NAME = os.environ['CHAT_TABLE_NAME']

devops_agent = boto3.client('devops-agent')
ddb = boto3.client('dynamodb')

# Cap the size of context we forward so a runaway payload can't turn into a
# runaway agent invocation cost.
MAX_CONTEXT_CHARS = 20000


def _put_status(chat_id, status, extra=None):
    """Idempotent UpdateItem writing the terminal status + optional payload."""
    expr_names = {'#s': 'status'}
    expr_values = {':s': {'S': status}}
    update_parts = ['#s = :s']
    if extra:
        for i, (k, v) in enumerate(extra.items()):
            name_key = f'#f{i}'
            value_key = f':v{i}'
            expr_names[name_key] = k
            expr_values[value_key] = {'S': str(v)[:8000]} if v is not None else {'NULL': True}
            update_parts.append(f'{name_key} = {value_key}')
    ddb.update_item(
        TableName=CHAT_TABLE_NAME,
        Key={'chatId': {'S': chat_id}},
        UpdateExpression='SET ' + ', '.join(update_parts),
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )


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

    Returns (final_text, error_message). One will always be None. This
    function does not raise on stream-level errors — it captures them so
    the caller can persist the failure.
    """
    events = response.get('events')
    if events is None:
        return None, 'no_event_stream'

    # DevOps Agent returns multiple content blocks per response — a primary
    # answer block plus decorative blocks (titles, reasoning, tool traces).
    # Track them separately by index so we can pick the "main" one at the
    # end rather than concatenating everything (which double-emits text).
    blocks = {}  # index -> {'type': str|None, 'text': str}
    error = None
    start = time.time()

    for event in events:
        if 'heartbeat' in event or 'responseCreated' in event or 'responseInProgress' in event:
            continue
        if 'contentBlockStart' in event:
            b = event['contentBlockStart']
            idx = b.get('index')
            if idx is not None:
                blocks.setdefault(idx, {'type': b.get('type'), 'text': ''})
                blocks[idx]['type'] = b.get('type') or blocks[idx].get('type')
            continue
        if 'contentBlockDelta' in event:
            b = event['contentBlockDelta']
            idx = b.get('index')
            delta = (b.get('delta') or {}).get('textDelta') or {}
            text_delta = delta.get('text')
            if idx is not None and text_delta:
                blocks.setdefault(idx, {'type': None, 'text': ''})
                blocks[idx]['text'] += text_delta
            continue
        if 'contentBlockStop' in event:
            # Some content blocks send the whole assembled text here even
            # if no deltas fired. Use it as a fallback per index.
            b = event['contentBlockStop']
            idx = b.get('index')
            block_text = b.get('text')
            if idx is not None and block_text:
                blocks.setdefault(idx, {'type': b.get('type'), 'text': ''})
                if not blocks[idx]['text']:
                    blocks[idx]['text'] = block_text
            continue
        if 'summary' in event:
            # Reserved for a future "agent reasoning" side panel.
            continue
        if 'responseCompleted' in event:
            break
        if 'responseFailed' in event:
            f = event['responseFailed']
            error = f.get('errorMessage') or f.get('errorCode') or 'response_failed'
            break

    elapsed = time.time() - start
    logger.info(f'Consumed {len(blocks)} content blocks in {elapsed:.1f}s: '
                f'{[(i, b.get("type"), len(b.get("text","")) ) for i, b in sorted(blocks.items())]}')

    if error:
        return None, error

    # Pick the primary answer: prefer explicit type="text" blocks; fall back
    # to the longest block; strip anything that looks like a bare title.
    def _is_title(t):
        return t and '\n' not in t and len(t) < 60

    text_blocks = [b['text'] for i, b in sorted(blocks.items())
                   if b.get('text') and not _is_title(b['text'])]
    if not text_blocks:
        return None, 'empty_response'

    # De-duplicate: many responses emit the same block twice. Keep first
    # occurrence of each unique text.
    seen = set()
    uniq = []
    for t in text_blocks:
        key = t.strip()
        if key in seen:
            continue
        seen.add(key)
        uniq.append(t)

    answer = '\n\n'.join(uniq).strip()
    return (answer, None) if answer else (None, 'empty_response')


def handler(event, context):
    chat_id = event.get('chatId')
    question = (event.get('question') or '').strip()
    pipeline_context = event.get('pipelineContext') or {}

    if not chat_id or not question:
        logger.error('Missing chatId or question in event')
        return {'ok': False, 'error': 'invalid_event'}

    try:
        create_resp = devops_agent.create_chat(agentSpaceId=AGENT_SPACE_ID)
        execution_id = create_resp.get('executionId') or create_resp.get('chatId')
        if not execution_id:
            _put_status(chat_id, 'failed', {'error': 'no_execution_id_returned'})
            return {'ok': False}

        send_resp = devops_agent.send_message(
            agentSpaceId=AGENT_SPACE_ID,
            executionId=execution_id,
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
