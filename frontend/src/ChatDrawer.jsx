import { useEffect, useMemo, useRef, useState } from 'react';
import { startChat, getChatStatus } from './pipelineService.js';

const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes — matches the worker Lambda timeout
const NOT_CONFIGURED = 'devops_agent_not_configured';
const DEFAULT_SETUP_URL =
  'https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-creating-an-agent-space.html';

// Normalize API/worker failures into { code, message, setupUrl }.
function toError(src, fallback) {
  if (typeof src === 'string') return { code: src };
  return {
    code: src?.error || fallback,
    message: src?.message,
    setupUrl: src?.setupUrl,
  };
}

/**
 * ChatDrawer — DevOps Agent chat pinned to the bottom-right of the dashboard.
 *
 * Uses the async request-response pattern:
 *   1. POST /api/chat  → returns `{ chatId, status: 'processing' }`
 *   2. Poll GET /api/chat/{chatId} every 2s until status is 'succeeded' or
 *      'failed'.
 *
 * DevOps Agent investigations can take 20-120+ seconds, which is why the
 * backend runs the actual `send_message` call in an async worker Lambda
 * instead of blocking API Gateway (which has a 30-second hard timeout).
 */
export default function ChatDrawer({ pipelines }) {
  const [open, setOpen] = useState(false);
  const [pipelineName, setPipelineName] = useState('');
  const [question, setQuestion] = useState('');
  const [busy, setBusy] = useState(false);
  const [response, setResponse] = useState(null);
  const [error, setError] = useState(null);
  const [elapsedMs, setElapsedMs] = useState(0);
  const textareaRef = useRef(null);
  const cancelRef = useRef(false);

  useEffect(() => {
    if (!open || pipelineName) return;
    const list = pipelines || [];
    const failed = list.find((p) => p.status === 'Failed');
    const pick = failed || list[0];
    if (pick) setPipelineName(pick.name);
  }, [open, pipelineName, pipelines]);

  useEffect(() => {
    if (open && textareaRef.current) textareaRef.current.focus();
  }, [open]);

  const selectedPipeline = useMemo(
    () => (pipelines || []).find((p) => p.name === pipelineName) || null,
    [pipelines, pipelineName]
  );

  useEffect(() => () => { cancelRef.current = true; }, []);

  async function submit() {
    if (!question.trim() || !selectedPipeline || busy) return;
    setBusy(true);
    setError(null);
    setResponse(null);
    setElapsedMs(0);
    cancelRef.current = false;

    const started = Date.now();
    const startResult = await startChat({
      question: question.trim(),
      pipelineContext: selectedPipeline,
    });
    if (startResult?.error) {
      setError(toError(startResult));
      setBusy(false);
      return;
    }
    const chatId = startResult.chatId;
    if (!chatId) {
      setError(toError('missing_chat_id'));
      setBusy(false);
      return;
    }

    const timer = setInterval(() => setElapsedMs(Date.now() - started), 500);
    try {
      while (!cancelRef.current) {
        if (Date.now() - started > POLL_TIMEOUT_MS) {
          setError(toError('chat_timeout'));
          break;
        }
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        if (cancelRef.current) break;
        const status = await getChatStatus(chatId);
        if (status?.error && status.status !== 'failed') {
          setError(toError(status));
          break;
        }
        if (status.status === 'succeeded') {
          setResponse(status);
          break;
        }
        if (status.status === 'failed') {
          setError(toError(status, 'chat_failed'));
          break;
        }
      }
    } finally {
      clearInterval(timer);
      setBusy(false);
    }
  }

  function onKeyDown(e) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      submit();
    }
  }

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className="fixed bottom-4 right-4 z-30 inline-flex items-center gap-2 h-10 px-4 rounded-full bg-[#0972d3] text-white text-[13px] font-medium shadow-[0_6px_20px_-6px_rgba(9,114,211,0.6)] hover:bg-[#033160] transition-colors"
        title="Ask AWS DevOps Agent about a pipeline"
      >
        <svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
          <path d="M14 6.5A5.5 5.5 0 0 1 8.5 12H6l-3 2v-3.4A5.5 5.5 0 1 1 14 6.5Z" />
        </svg>
        Ask DevOps Agent
      </button>
    );
  }

  return (
    <div className="fixed bottom-0 right-0 z-30 w-full sm:w-[520px] bg-white border-l border-t border-[#d1d5db] rounded-tl-[6px] shadow-[0_-8px_24px_-8px_rgba(0,28,36,0.18)] flex flex-col max-h-[70vh]">
      <header className="px-4 py-3 border-b border-[#eaedf0] flex items-center justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[13px] font-bold text-[#16191f]">AWS DevOps Agent</div>
          <div className="text-[11.5px] text-[#5f6b7a]">
            Ask about the selected pipeline — the agent will investigate live AWS resources.
          </div>
        </div>
        <button
          onClick={() => setOpen(false)}
          className="h-7 w-7 rounded-sm hover:bg-[#f7f8f8] inline-flex items-center justify-center text-[#5f6b7a]"
          aria-label="Close chat"
        >
          <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="m4 4 8 8M12 4l-8 8" />
          </svg>
        </button>
      </header>

      <div className="px-4 py-3 border-b border-[#eaedf0] bg-[#fafbfb]">
        <label className="block text-[11px] uppercase tracking-[0.06em] font-semibold text-[#7d8998] mb-1">Pipeline</label>
        <select
          value={pipelineName}
          onChange={(e) => { setPipelineName(e.target.value); setResponse(null); setError(null); }}
          className="w-full h-8 px-2 rounded-[2px] bg-white text-[12.5px] text-[#16191f] border border-[#d1d5db] focus:border-[#0972d3] focus:ring-2 focus:ring-[#0972d3]/20 outline-hidden"
        >
          {(pipelines || []).length === 0 && <option value="">No pipelines available</option>}
          {(pipelines || []).map((p) => (
            <option key={p.name} value={p.name}>{p.name} — {p.status}</option>
          ))}
        </select>
      </div>

      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3 text-[13px] text-[#16191f]">
        {!response && !error && !busy && (
          <div className="text-[12.5px] text-[#5f6b7a] leading-relaxed">
            Ask about the selected pipeline — for example:
            <ul className="mt-2 space-y-1 list-disc pl-5">
              <li>Why is this pipeline failing?</li>
              <li>Which stage is the bottleneck?</li>
              <li>What changed since the last successful run?</li>
              <li>Look at the latest CodeBuild logs and summarize the error.</li>
            </ul>
            <p className="mt-3 text-[11px] text-[#7d8998]">
              Investigations typically take 20–90 seconds.
            </p>
          </div>
        )}
        {busy && (
          <div className="text-[12.5px] text-[#5f6b7a]">
            <div className="inline-flex items-center gap-2">
              <span className="inline-block h-2 w-2 rounded-full bg-[#0972d3] animate-pulse" />
              Agent is investigating…
            </div>
            <div className="mt-1 font-mono text-[11px] text-[#7d8998]">
              {(elapsedMs / 1000).toFixed(0)}s elapsed
            </div>
          </div>
        )}
        {error && error.code === NOT_CONFIGURED && (
          <div className="rounded-lg border-2 border-[#0972d3] bg-[#f2f8fd] px-3 py-2.5 text-[12.5px] text-[#000716]">
            <div className="flex items-center gap-1.5 font-bold text-[13px]">
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="#0972d3" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
                <circle cx="8" cy="8" r="7"/><path d="M8 7v4M8 4.5v.5"/>
              </svg>
              AWS DevOps Agent isn't set up
            </div>
            <p className="mt-1 leading-relaxed text-[#414d5c]">
              {error.message || 'No DevOps Agent AgentSpace is configured for this dashboard.'}
            </p>
            <ol className="mt-2 pl-5 list-decimal space-y-0.5 text-[#414d5c]">
              <li>Create an AgentSpace in this account and region, with this account associated.</li>
              <li>
                Redeploy with its ID:{' '}
                <code className="font-mono text-[11.5px] bg-white border border-[#d1d5db] rounded-sm px-1">
                  make deploy-cfn-dashboard DEVOPS_AGENT_SPACE_ID=&lt;id&gt;
                </code>
              </li>
            </ol>
            <a
              href={error.setupUrl || DEFAULT_SETUP_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="mt-2 inline-flex items-center gap-1 font-bold text-[#0972d3] hover:text-[#033160] hover:underline"
            >
              How to create an AgentSpace
              <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M6 3H3v10h10v-3M9.5 2.5h4v4M13 3 7 9"/>
              </svg>
            </a>
          </div>
        )}
        {error && error.code !== NOT_CONFIGURED && (
          <div className="rounded-lg border border-[#f1cdc7] bg-[#fdf3f1] text-[#d91515] px-3 py-2 text-[12.5px]">
            <div className="font-semibold mb-0.5">Chat failed</div>
            <div className="font-mono text-[11.5px] wrap-break-word">{error.code}</div>
            {error.message && <div className="mt-1 text-[12px] wrap-break-word text-[#5f6b7a]">{error.message}</div>}
          </div>
        )}
        {response?.answer && (
          <div className="rounded-[2px] border border-[#e9ebed] bg-white px-3 py-2 whitespace-pre-wrap leading-relaxed">
            {response.answer}
            {response.agentSpaceId && (
              <div className="mt-2 pt-2 border-t border-[#eaedf0] text-[10.5px] font-mono text-[#7d8998]">
                AgentSpace: {response.agentSpaceId}
              </div>
            )}
          </div>
        )}
      </div>

      <div className="px-4 py-3 border-t border-[#eaedf0] bg-white">
        <textarea
          ref={textareaRef}
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder={selectedPipeline ? `Ask about ${selectedPipeline.name}…` : 'Select a pipeline first…'}
          disabled={!selectedPipeline || busy}
          rows={2}
          className="w-full resize-none px-2.5 py-1.5 rounded-[2px] bg-white text-[13px] text-[#16191f] border border-[#d1d5db] focus:border-[#0972d3] focus:ring-2 focus:ring-[#0972d3]/20 outline-hidden disabled:opacity-60"
        />
        <div className="mt-2 flex items-center justify-between">
          <span className="text-[10.5px] text-[#7d8998]">{question.length}/2000 · ⌘/Ctrl + Enter to send</span>
          <button
            onClick={submit}
            disabled={!question.trim() || !selectedPipeline || busy}
            className="inline-flex items-center justify-center gap-1.5 h-8 px-3 rounded-[20px] text-[13px] font-medium bg-[#ec7211] text-white hover:bg-[#d96813] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {busy ? 'Investigating…' : 'Ask'}
          </button>
        </div>
      </div>
    </div>
  );
}
