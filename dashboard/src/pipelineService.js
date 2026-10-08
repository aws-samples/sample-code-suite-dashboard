/**
 * pipelineService.js
 * Single seam between the UI and the AWS data layer.
 *
 * Calls the dashboard API (API Gateway → StatsLambda) via the Vite dev
 * server's `/api/*` proxy. The proxy signs each request with SigV4 using
 * the developer's local AWS credentials (see dashboard/vite.config.js).
 * The browser never sees AWS credentials and the API is never reachable
 * unauthenticated.
 *
 * Override the proxy mount point with VITE_API_BASE if you wire up a
 * different reverse-proxy path; the default `/api` matches vite.config.js.
 *
 * The Lambda exposes:
 *   GET /accounts   -> [{ id, alias, region }]
 *   GET /pipelines  -> { pipelines: [...flattened rows...], errors: [] }
 *   GET /stats      -> { total, running, failed24h, successRate, runs24h }
 */

const API_BASE = (import.meta.env.VITE_API_BASE || '/api').replace(/\/$/, '');

async function getJson(path) {
  const res = await fetch(`${API_BASE}${path}`, {
    method: 'GET',
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) {
    // Don't echo the response body — it may contain server-side detail we
    // don't want surfaced in the UI. Keep the status for debugging.
    throw new Error(`GET ${path} failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}

// Normalize a pipeline row so the UI can safely call .filter / .some / .map
// even if the backend ever changes shape or drops a field.
function normalizePipeline(p) {
  if (!p || typeof p !== 'object') return null;
  return {
    ...p,
    name: p.name || '',
    accountId: p.accountId || '',
    accountAlias: p.accountAlias || '',
    repository: p.repository || '—',
    branch: p.branch || 'main',
    status: p.status || 'Stopped',
    version: p.version || '—',
    stages: Array.isArray(p.stages) ? p.stages : [],
    history: Array.isArray(p.history) ? p.history : [],
    lastRunStart: Number(p.lastRunStart) || 0,
    durationMs: Number(p.durationMs) || 0,
  };
}

export async function listAccounts() {
  try {
    const accounts = await getJson('/accounts');
    return Array.isArray(accounts) ? accounts : [];
  } catch (err) {
    console.error('[pipelineService] listAccounts failed:', err);
    return [];
  }
}

export async function listAllPipelines(accountIds) {
  try {
    const data = await getJson('/pipelines');
    const rawPipelines = Array.isArray(data?.pipelines) ? data.pipelines : [];
    const allPipelines = rawPipelines.map(normalizePipeline).filter(Boolean);
    const errors = Array.isArray(data?.errors) ? data.errors : [];
    const pipelines = accountIds && accountIds.length
      ? allPipelines.filter(p => accountIds.includes(p.accountId))
      : allPipelines;
    return { pipelines, errors };
  } catch (err) {
    console.error('[pipelineService] listAllPipelines failed:', err);
    return { pipelines: [], errors: [{ error: err.message || String(err) }] };
  }
}

export async function getStats() {
  try {
    return await getJson('/stats');
  } catch (err) {
    console.error('[pipelineService] getStats failed:', err);
    return null;
  }
}

/**
 * Kick off a DevOps Agent chat request. Returns `{ chatId }` on success —
 * the backend is async, so the caller must poll `getChatStatus(chatId)`
 * until status is 'succeeded' or 'failed'.
 */
export async function startChat({ question, pipelineContext }) {
  try {
    const res = await fetch(`${API_BASE}/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ question, pipelineContext }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return { error: body?.error || `chat_failed_${res.status}` };
    return body;
  } catch (err) {
    console.error('[pipelineService] startChat failed:', err);
    return { error: err.message || String(err) };
  }
}

/**
 * Fetch the current state of a chat request. Returns `{ chatId, status,
 * answer?, error?, agentSpaceId? }`. Poll every ~2s until status !==
 * 'processing'.
 */
export async function getChatStatus(chatId) {
  try {
    const res = await fetch(`${API_BASE}/chat/${encodeURIComponent(chatId)}`, {
      method: 'GET',
      headers: { Accept: 'application/json' },
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return { error: body?.error || `chat_status_failed_${res.status}` };
    return body;
  } catch (err) {
    console.error('[pipelineService] getChatStatus failed:', err);
    return { error: err.message || String(err) };
  }
}

// Real data refreshes itself; this is a no-op kept for API compatibility.
export function advanceMockClock() {}

// Status / trigger / stages constants — kept for API compatibility with the
// previous mock-backed module. The UI uses string literals directly.
export const STATUS = {
  SUCCEEDED: 'Succeeded',
  IN_PROGRESS: 'InProgress',
  FAILED: 'Failed',
  STOPPED: 'Stopped',
};

export const TRIGGER = {
  TAG: 'GitTag',
  MERGE: 'BranchMerge',
  MANUAL: 'Manual',
  SCHEDULE: 'Schedule',
};

export const STAGES_LIST = ['Source', 'Build', 'Test', 'Deploy'];
