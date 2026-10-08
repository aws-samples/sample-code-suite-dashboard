import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { BarChart, Bar, Cell, ResponsiveContainer, Tooltip } from 'recharts';
import * as pipelineService from './pipelineService.js';
import ChatDrawer from './ChatDrawer.jsx';

const REFRESH_INTERVAL_MS = 30_000;

const C = {
  text:        "text-[#16191f]",
  textSub:     "text-[#5f6b7a]",
  textMuted:   "text-[#7d8998]",
  link:        "text-[#0972d3]",
  linkHover:   "hover:text-[#033160]",
  border:      "border-[#e9ebed]",
  borderHard:  "border-[#d1d5db]",
  surface:     "bg-white",
  surface2:    "bg-[#f7f8f8]",
  surface3:    "bg-[#f2f3f3]",
};

const STATUS_TOKENS = {
  Succeeded:  { label: "Succeeded",   fg: "text-[#037f0c]",  bg: "bg-[#f2f8f0]", border: "border-[#cfe5cf]" },
  InProgress: { label: "In progress", fg: "text-[#0073bb]",  bg: "bg-[#f1f8fd]", border: "border-[#cee0f5]", pulse: true },
  Failed:     { label: "Failed",      fg: "text-[#d91515]",  bg: "bg-[#fdf3f1]", border: "border-[#f1cdc7]" },
  Stopped:    { label: "Stopped",     fg: "text-[#5f6b7a]",  bg: "bg-[#f2f3f3]", border: "border-[#d1d5db]" },
};

const STAGE_FILL = {
  Succeeded:  "bg-[#037f0c]",
  InProgress: "bg-[#0073bb]",
  Failed:     "bg-[#d91515]",
  Stopped:    "bg-[#7d8998]",
  null:       "bg-[#e9ebed]",
};

function fmtAgo(ms) {
  const diff = Date.now() - ms;
  const s = Math.max(1, Math.floor(diff / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}
function fmtDuration(ms) {
  const s = Math.max(1, Math.floor(ms / 1000));
  const m = Math.floor(s / 60);
  const rem = s % 60;
  if (m === 0) return `${s}s`;
  return `${m}m ${String(rem).padStart(2, "0")}s`;
}
function fmtAbsolute(ms) {
  const d = new Date(ms);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

const Icon = {
  Check: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" {...p}>
      <circle cx="8" cy="8" r="7"/><path d="m5 8 2 2 4-4"/>
    </svg>
  ),
  X: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" {...p}>
      <circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5"/>
    </svg>
  ),
  Dot: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" {...p}>
      <circle cx="8" cy="8" r="7"/><circle cx="8" cy="8" r="2" fill="currentColor" stroke="none"/>
    </svg>
  ),
  Minus: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" {...p}>
      <circle cx="8" cy="8" r="7"/><path d="M5 8h6"/>
    </svg>
  ),
  Refresh: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" {...p}>
      <path d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9"/><path d="M13.5 2.5v3h-3"/>
    </svg>
  ),
  Caret: (p) => (
    <svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}>
      <path d="m3 4.5 3 3 3-3"/>
    </svg>
  ),
  Search: (p) => (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" {...p}>
      <circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/>
    </svg>
  ),
  External: (p) => (
    <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" {...p}>
      <path d="M6 3H3v10h10v-3M9.5 2.5h4v4M13 3 7 9"/>
    </svg>
  ),
  Tag: (p) => (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.4" {...p}>
      <path d="M8.5 1.5h5v5L7 13 2 8l6.5-6.5z"/><circle cx="11" cy="4" r=".9" fill="currentColor" stroke="none"/>
    </svg>
  ),
  Branch: (p) => (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.4" {...p}>
      <circle cx="4" cy="3" r="1.5"/><circle cx="4" cy="13" r="1.5"/><circle cx="12" cy="6" r="1.5"/>
      <path d="M4 4.5v7M4 10c0-3 8-2 8-4.5"/>
    </svg>
  ),
  Hand: (p) => (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.4" {...p}>
      <path d="M5 9V3.5a1 1 0 1 1 2 0V8M7 8V2.5a1 1 0 1 1 2 0V8M9 8V3.5a1 1 0 1 1 2 0V9M11 7a1 1 0 1 1 2 0v4a4 4 0 0 1-8 0V7"/>
    </svg>
  ),
  Clock: (p) => (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.4" {...p}>
      <circle cx="8" cy="8" r="6"/><path d="M8 5v3.5l2 1.2"/>
    </svg>
  ),
};

function TriggerGlyph({ type, className = "" }) {
  const M = { GitTag: Icon.Tag, BranchMerge: Icon.Branch, Manual: Icon.Hand, Schedule: Icon.Clock };
  const Cmp = M[type] || Icon.Tag;
  return <Cmp className={className} />;
}
function triggerLabel(t) {
  return { GitTag: "Git tag push", BranchMerge: "Branch merge", Manual: "Manual run", Schedule: "Scheduled" }[t] || t;
}

// Framework / language inference + colored dot.
const FRAMEWORKS = {
  java:       { label: "Java",       color: "#e76f00" },
  python:     { label: "Python",     color: "#16a34a" },
  typescript: { label: "TypeScript", color: "#db2777" },
  javascript: { label: "JavaScript", color: "#ca8a04" },
  dotnet:     { label: ".NET",       color: "#7c3aed" },
  go:         { label: "Go",         color: "#0d9488" },
  rust:       { label: "Rust",       color: "#b45309" },
  ruby:       { label: "Ruby",       color: "#cc342d" },
};

// Map known demo apps + heuristics from the pipeline / repo name.
function detectFramework(p) {
  const hay = `${p.name || ""} ${p.repository || ""}`.toLowerCase();
  const known = [
    ["payments-gateway",      "java"],
    ["data-ingestion-worker", "python"],
    ["shop-checkout-api",     "dotnet"],
    ["growth-marketing-site", "typescript"],
    ["search-frontend",       "typescript"],
    ["react-cicd",            "typescript"],
  ];
  for (const [k, v] of known) if (hay.includes(k)) return v;
  if (/\b(python|django|flask|fastapi|pyspark)\b/.test(hay)) return "python";
  if (/\b(java|spring|maven|gradle|kotlin)\b/.test(hay))     return "java";
  if (/\b(dotnet|\.net|csharp|aspnet)\b/.test(hay))           return "dotnet";
  if (/\b(typescript|tsx|next|nest)\b/.test(hay))             return "typescript";
  if (/\b(react|vue|angular|node|frontend|web|ui)\b/.test(hay)) return "typescript";
  if (/\b(go|golang)\b/.test(hay))                            return "go";
  if (/\b(rust|cargo)\b/.test(hay))                           return "rust";
  if (/\b(ruby|rails)\b/.test(hay))                           return "ruby";
  return null;
}

function FrameworkDot({ framework, size = 9 }) {
  const f = framework && FRAMEWORKS[framework];
  if (!f) return null;
  return (
    <span
      title={f.label}
      aria-label={`Framework: ${f.label}`}
      className="inline-block rounded-full ring-1 ring-black/10 shrink-0"
      style={{ width: size, height: size, backgroundColor: f.color }}
    />
  );
}

function hexToRgba(hex, alpha) {
  const h = hex.replace("#", "");
  const n = h.length === 3
    ? h.split("").map(c => c + c).join("")
    : h;
  const r = parseInt(n.slice(0, 2), 16);
  const g = parseInt(n.slice(2, 4), 16);
  const b = parseInt(n.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function PillButton({ children, onClick, disabled, primary, dropdown, title, className = "" }) {
  const base = "inline-flex items-center justify-center gap-2 h-8 px-3 rounded-[20px] text-[13px] font-medium transition-colors select-none whitespace-nowrap";
  const variant = primary
    ? "bg-[#ec7211] text-white hover:bg-[#d96813] border border-[#ec7211]"
    : "bg-white text-[#16191f] border border-[#7d8998] hover:bg-[#f7f8f8]";
  const dis = disabled ? "opacity-50 cursor-not-allowed" : "cursor-pointer";
  return (
    <button onClick={onClick} disabled={disabled} title={title} className={`${base} ${variant} ${dis} ${className}`}>
      <span>{children}</span>
      {dropdown && <Icon.Caret className="opacity-70 ml-0.5"/>}
    </button>
  );
}

function StatusBadge({ status, size = "md" }) {
  const t = STATUS_TOKENS[status];
  if (!t) return null;
  const I = status === "Succeeded" ? Icon.Check
          : status === "Failed"    ? Icon.X
          : status === "InProgress"? Icon.Dot
          :                          Icon.Minus;
  const txt = size === "sm" ? "text-[12px]" : "text-[13px]";
  return (
    <span className={`inline-flex items-center gap-1.5 ${t.fg} ${txt} font-normal`}>
      <span className="relative inline-flex">
        {t.pulse && <span className="absolute inset-0 rounded-full bg-[#0073bb] opacity-40 animate-ping"/>}
        <I className="relative" />
      </span>
      {t.label}
    </span>
  );
}

function AccountChip({ alias, id }) {
  const prod = alias === "prod";
  const border = prod ? "border-[#f0c096]" : "border-[#cee0f5]";
  const bg     = prod ? "bg-[#fef6f0]"     : "bg-[#f1f8fd]";
  const fg     = prod ? "text-[#b15c00]"   : "text-[#0073bb]";
  return (
    <span className={`inline-flex items-center gap-1.5 ${bg} ${fg} ${border} border rounded-[10px] px-1.5 py-0.5 text-[11px] font-medium`}>
      <span className="uppercase tracking-wide">{alias}</span>
      <span className="font-mono opacity-70 normal-case tracking-normal">{id.split("-")[1]}</span>
    </span>
  );
}

function BranchTag({ branch }) {
  if (!branch) return null;
  const kind = branch.startsWith("feature/") ? "feature"
             : branch.startsWith("bugfix/")  ? "bugfix"
             : "main";
  const styles = {
    feature: { fg: "text-[#5b21b6]", bg: "bg-[#f5f0fb]", border: "border-[#dcd0ee]" },
    bugfix:  { fg: "text-[#b15c00]", bg: "bg-[#fef6f0]", border: "border-[#f0c096]" },
    main:    { fg: "text-[#5f6b7a]", bg: "bg-[#f2f3f3]", border: "border-[#d1d5db]" },
  }[kind];
  return (
    <span className={`inline-flex items-center gap-1 ${styles.bg} ${styles.fg} ${styles.border} border rounded-[10px] px-1.5 py-0.5 font-mono text-[11px] max-w-[220px]`} title={branch}>
      <svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="4" cy="3" r="1.4"/><circle cx="4" cy="13" r="1.4"/><circle cx="12" cy="6" r="1.4"/>
        <path d="M4 4.4v7.2M4 10c0-3 8-2 8-4.4"/>
      </svg>
      <span className="truncate">{branch}</span>
    </span>
  );
}

function StageStepper({ stages }) {
  return (
    <ol className="flex items-stretch gap-1.5">
      {stages.map((s, i) => {
        const fill = STAGE_FILL[s.status ?? "null"];
        const running = s.status === "InProgress";
        const done    = s.status === "Succeeded";
        const failed  = s.status === "Failed";
        const colorClass = done    ? "text-[#037f0c]"
                         : running ? "text-[#0073bb] font-medium"
                         : failed  ? "text-[#d91515]"
                         :           "text-[#5f6b7a]";
        // Each stage's `url` deep-links into the stage's underlying provider
        // (CodeBuild for Build stages, CodeCommit for Source, etc).
        const labelTitle = s.url ? `Open ${s.name} in AWS console` : s.name;
        const Label = s.url ? "a" : "span";
        const labelProps = s.url
          ? {
              href: s.url,
              target: "_blank",
              rel: "noopener noreferrer",
              className: `${colorClass} hover:underline cursor-pointer`,
              title: labelTitle,
            }
          : { className: colorClass };
        return (
          <li key={s.name} className="flex-1 min-w-0">
            <div className="relative h-1 rounded-full bg-[#eaedf0] overflow-hidden">
              <div className={`absolute inset-y-0 left-0 ${fill}`} style={{ width: s.status ? "100%" : "0%" }} />
              {running && <div className="absolute inset-y-0 left-0 w-1/3 bg-white/55 animate-[shimmer_1.6s_linear_infinite]"/>}
            </div>
            <div className="mt-1.5 flex items-center gap-1 text-[11px]">
              <span className={`font-mono tabular-nums ${C.textMuted}`}>{i + 1}</span>
              <Label {...labelProps}>{s.name}</Label>
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function Sparkline({ history }) {
  const data = history.map((h, i) => ({
    i,
    v: Math.max(0.3, Math.min(1, (h.durationMs || 60_000) / 600_000)),
    status: h.status,
  }));
  return (
    <div className="h-7 w-[104px]">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} barCategoryGap={2}>
          <Tooltip
            cursor={false}
            wrapperStyle={{ outline: "none" }}
            contentStyle={{
              background: "#ffffff", border: "1px solid #d1d5db", borderRadius: 4,
              fontFamily: "Inter, sans-serif", fontSize: 11, padding: "4px 6px",
              boxShadow: "0 2px 6px rgba(0,0,0,0.08)",
            }}
            labelFormatter={() => ""}
            formatter={(_, __, item) => [item.payload.status, `run -${10 - item.payload.i}`]}
          />
          <Bar dataKey="v" radius={[1, 1, 0, 0]}>
            {data.map((d, i) => (
              <Cell key={i} fill={
                d.status === "Succeeded" ? "#037f0c"
                : d.status === "Failed"  ? "#d91515"
                :                          "#9aa7b5"
              } />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

function PipelineCard({ p }) {
  const successCount = p.history.filter(h => h.status === "Succeeded").length;
  const successRate = Math.round((successCount / Math.max(1, p.history.length)) * 100);
  const framework = detectFramework(p);
  const fwMeta = framework ? FRAMEWORKS[framework] : null;
  const accent = fwMeta ? fwMeta.color : "#9aa7b5";
  return (
    <article className="bg-white border border-[#e9ebed] rounded-[2px] hover:border-[#9aa7b5] hover:shadow-[0_1px_4px_-1px_rgba(0,28,36,0.1)] transition-all">
      <header className="px-4 pt-3.5 pb-3 border-b border-[#eaedf0]">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <a href={p.logsUrl} target="_blank" rel="noopener noreferrer"
               className={`block truncate text-[15px] font-bold ${C.link} hover:underline`} title={p.name}>
              {p.name}
            </a>
            <div className="mt-1 flex items-center gap-2 flex-wrap text-[12px]">
              {fwMeta && (
                <span
                  title={fwMeta.label}
                  className="inline-flex items-center gap-1.5 border rounded-[10px] px-1.5 py-0.5 text-[11px] font-medium"
                  style={{
                    borderColor: hexToRgba(accent, 0.4),
                    backgroundColor: hexToRgba(accent, 0.10),
                    color: accent,
                  }}
                >
                  <FrameworkDot framework={framework}/>
                  {fwMeta.label}
                </span>
              )}
              <AccountChip alias={p.accountAlias} id={p.accountId}/>
              <span className={`font-mono ${C.textSub}`}>{p.repository}</span>
              <BranchTag branch={p.branch}/>
            </div>
          </div>
          <StatusBadge status={p.status}/>
        </div>
      </header>
      <div className="px-4 pt-3 pb-3">
        <div className="flex items-center justify-between mb-2">
          <span className={`text-[11px] uppercase tracking-[0.06em] font-semibold ${C.textMuted}`}>Stages</span>
          <span className={`text-[11px] font-mono tabular-nums ${C.textSub}`} title={triggerLabel(p.triggerType)}>
            <TriggerGlyph type={p.triggerType} className="inline-block align-[-2px] mr-1 text-[#5f6b7a]"/>
            {triggerLabel(p.triggerType)}
          </span>
        </div>
        <StageStepper stages={p.stages}/>
      </div>
      <div className="px-4 pb-3 grid grid-cols-3 gap-x-3 gap-y-2 text-[12.5px]">
        <div className="min-w-0">
          <div className={`text-[10.5px] uppercase tracking-[0.06em] font-semibold ${C.textMuted}`}>Version</div>
          <div className={`font-mono tabular-nums ${C.text} truncate`}>{p.version}</div>
        </div>
        <div className="min-w-0">
          <div className={`text-[10.5px] uppercase tracking-[0.06em] font-semibold ${C.textMuted}`}>Last run</div>
          <div className={`font-mono tabular-nums ${C.text} truncate`}>{fmtAgo(p.lastRunStart)}</div>
        </div>
        <div className="min-w-0">
          <div className={`text-[10.5px] uppercase tracking-[0.06em] font-semibold ${C.textMuted}`}>Duration</div>
          <div className={`font-mono tabular-nums ${C.text} truncate`}>{fmtDuration(p.durationMs)}</div>
        </div>
      </div>
      <footer className="px-4 py-2.5 border-t border-[#eaedf0] bg-[#fafbfb] flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <Sparkline history={p.history}/>
          <span className={`text-[11.5px] font-mono tabular-nums ${C.textSub}`}>
            <span className="text-[#037f0c]">{successCount}</span>
            <span className={C.textMuted}>/{p.history.length}</span>
            <span className="mx-1 text-[#7d8998]">·</span>
            {successRate}%
          </span>
        </div>
        <a href={p.logsUrl} target="_blank" rel="noopener noreferrer"
           className={`inline-flex items-center gap-1.5 text-[12.5px] ${C.link} ${C.linkHover} hover:underline`}>
          View logs <Icon.External/>
        </a>
      </footer>
    </article>
  );
}

function StatCard({ label, value, sub, tone = "default", onClick, active }) {
  const valueColor = {
    default: "text-[#16191f]",
    blue:    "text-[#0073bb]",
    green:   "text-[#037f0c]",
    red:     "text-[#d91515]",
  }[tone];
  const interactive = typeof onClick === "function";
  const Wrap = interactive ? "button" : "div";
  const wrapProps = interactive
    ? {
        onClick,
        type: "button",
        title: `Filter pipelines: ${label}`,
        className:
          "text-left bg-white border rounded-[2px] px-4 py-3.5 transition-colors cursor-pointer w-full " +
          (active
            ? "border-[#0972d3] ring-1 ring-[#0972d3]/30 bg-[#f1f8fd]"
            : "border-[#e9ebed] hover:border-[#9aa7b5] hover:bg-[#fafbfb]"),
      }
    : { className: "bg-white border border-[#e9ebed] rounded-[2px] px-4 py-3.5" };
  return (
    <Wrap {...wrapProps}>
      <div className={`text-[13px] font-bold ${C.text}`}>{label}</div>
      <div className="mt-1 flex items-baseline gap-2">
        <div className={`text-[28px] leading-none font-normal tabular-nums ${valueColor}`}>{value}</div>
      </div>
      <div className={`mt-1.5 text-[12px] ${C.textSub}`}>{sub}</div>
    </Wrap>
  );
}

function AccountSwitcher({ accounts, selected, onChange }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const ref = useRef(null);
  const searchRef = useRef(null);

  useEffect(() => {
    function onDocClick(e) { if (ref.current && !ref.current.contains(e.target)) setOpen(false); }
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, []);

  // Auto-focus the search box when the dropdown opens — at scale you almost
  // always want to filter rather than scroll.
  useEffect(() => {
    if (open && searchRef.current) {
      const t = setTimeout(() => searchRef.current?.focus(), 50);
      return () => clearTimeout(t);
    }
  }, [open]);

  const all = selected.length === accounts.length;
  const none = selected.length === 0;

  const label = all
    ? `All accounts (${accounts.length})`
    : none
      ? `0 of ${accounts.length}`
      : selected.length === 1
        ? `${accounts.find(a => a.id === selected[0])?.alias?.toUpperCase()} only`
        : `${selected.length} of ${accounts.length}`;

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return accounts;
    return accounts.filter(a => {
      const haystack = `${a.alias} ${a.id} ${a.region}`.toLowerCase();
      return haystack.includes(q);
    });
  }, [accounts, query]);

  // Treat the visible (filtered) list as the unit for "select all" /
  // "deselect all" so the buttons act on what the user is looking at.
  const visibleIds = useMemo(() => filtered.map(a => a.id), [filtered]);
  const visibleSelectedCount = useMemo(
    () => visibleIds.filter(id => selected.includes(id)).length,
    [visibleIds, selected]
  );

  function toggle(id) {
    if (selected.includes(id)) {
      onChange(selected.filter(x => x !== id));
    } else {
      onChange([...selected, id]);
    }
  }
  function selectVisible() {
    const set = new Set(selected);
    visibleIds.forEach(id => set.add(id));
    onChange([...set]);
  }
  function clearVisible() {
    if (visibleSelectedCount === 0) return;
    onChange(selected.filter(id => !visibleIds.includes(id)));
  }
  function selectOnly(id) {
    onChange([id]);
  }

  return (
    <div ref={ref} className="relative">
      <PillButton onClick={() => setOpen(o => !o)} dropdown>{label}</PillButton>
      {open && (
        <div className="absolute right-0 mt-1.5 w-[340px] bg-white border border-[#d1d5db] rounded-[2px] shadow-[0_4px_16px_-4px_rgba(0,28,36,0.18)] z-20">
          {/* Header — search */}
          <div className="px-2.5 pt-2.5 pb-2 border-b border-[#eaedf0]">
            <div className="relative">
              <Icon.Search className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#7d8998]"/>
              <input
                ref={searchRef}
                value={query}
                onChange={e => setQuery(e.target.value)}
                placeholder={`Search ${accounts.length} accounts…`}
                className="w-full h-8 pl-8 pr-7 rounded-[2px] bg-white text-[#16191f] text-[12.5px] placeholder:text-[#7d8998] outline-none border border-[#d1d5db] focus:border-[#0972d3] focus:ring-2 focus:ring-[#0972d3]/20"
              />
              {query && (
                <button
                  onClick={() => setQuery("")}
                  className="absolute right-1.5 top-1/2 -translate-y-1/2 text-[#7d8998] hover:text-[#16191f] h-5 w-5 inline-flex items-center justify-center rounded"
                  title="Clear"
                >
                  <Icon.X className="!w-3 !h-3"/>
                </button>
              )}
            </div>
            <div className="mt-2 flex items-center justify-between text-[11.5px] text-[#5f6b7a]">
              <span>
                <span className="font-mono tabular-nums text-[#16191f]">{selected.length}</span>
                <span className="text-[#7d8998]"> selected</span>
                {query && (
                  <span className="text-[#7d8998]"> · {filtered.length} match{filtered.length === 1 ? "" : "es"}</span>
                )}
              </span>
              <div className="flex items-center gap-1">
                <button
                  onClick={selectVisible}
                  disabled={visibleSelectedCount === filtered.length}
                  className="px-2 h-6 rounded text-[11.5px] text-[#0972d3] hover:bg-[#f1f8fd] disabled:opacity-40 disabled:hover:bg-transparent"
                  title="Select all visible"
                >
                  Select {query ? "matching" : "all"}
                </button>
                <span className="text-[#d1d5db]">·</span>
                <button
                  onClick={clearVisible}
                  disabled={visibleSelectedCount === 0}
                  className="px-2 h-6 rounded text-[11.5px] text-[#5f6b7a] hover:bg-[#f7f8f8] disabled:opacity-40 disabled:hover:bg-transparent"
                  title="Clear visible"
                >
                  Clear
                </button>
              </div>
            </div>
          </div>

          {/* Scrollable list */}
          <div className="max-h-[420px] overflow-y-auto py-1">
            {filtered.length === 0 ? (
              <div className="px-3 py-6 text-center text-[12px] text-[#7d8998]">
                No accounts match "{query}"
              </div>
            ) : (
              filtered.map(a => {
                const checked = selected.includes(a.id);
                const id12 = a.id.split("-")[1] || a.id;
                return (
                  <div
                    key={a.id}
                    className={`group w-full flex items-center gap-2 px-2.5 py-1.5 hover:bg-[#f1f8fd] ${checked ? "bg-[#f7fafc]" : ""}`}
                  >
                    <button
                      onClick={() => toggle(a.id)}
                      className="flex-1 min-w-0 flex items-center gap-2 text-left"
                      title={checked ? `Click to deselect ${a.alias}` : `Click to select ${a.alias}`}
                    >
                      <span
                        className={`shrink-0 inline-flex items-center justify-center w-4 h-4 rounded-[2px] border ${
                          checked
                            ? "bg-[#0972d3] border-[#0972d3] text-white"
                            : "bg-white border-[#7d8998]"
                        }`}
                      >
                        {checked && <Icon.Check className="!w-3 !h-3"/>}
                      </span>
                      <span className="min-w-0 flex-1 flex flex-col">
                        <span className="text-[12.5px] text-[#16191f] truncate">
                          <span className={
                            a.alias === "aws" ? "font-semibold text-[#16191f]"
                            : a.alias?.startsWith("prod") ? "font-medium text-[#b15c00]"
                            : "font-medium text-[#0073bb]"
                          }>{a.alias}</span>
                          <span className="text-[#7d8998]"> · </span>
                          <span className="font-mono text-[11.5px] text-[#5f6b7a]">{id12}</span>
                        </span>
                        <span className="font-mono text-[10.5px] text-[#7d8998]">{a.region}</span>
                      </span>
                    </button>
                    <button
                      onClick={() => selectOnly(a.id)}
                      className="opacity-0 group-hover:opacity-100 px-1.5 h-6 text-[10.5px] text-[#0972d3] hover:bg-[#e1effa] rounded transition-opacity"
                      title={`Show only ${a.alias}`}
                    >
                      Only
                    </button>
                  </div>
                );
              })
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function RefreshControl({ secondsLeft, onRefresh, refreshing }) {
  const total = REFRESH_INTERVAL_MS / 1000;
  const pct = Math.max(0, Math.min(1, 1 - secondsLeft / total));
  const RAD = 13;
  const CIRC = 2 * Math.PI * RAD;
  return (
    <div className="flex items-center gap-2">
      <button onClick={onRefresh} disabled={refreshing} title="Refresh now"
              className="relative inline-flex items-center justify-center h-8 w-8 rounded-full bg-white border border-[#7d8998] hover:bg-[#f7f8f8]">
        <svg className="absolute inset-0" viewBox="0 0 32 32" width="32" height="32">
          <circle cx="16" cy="16" r={RAD} fill="none" stroke="#e9ebed" strokeWidth="1.5"/>
          <circle cx="16" cy="16" r={RAD} fill="none" stroke="#0972d3" strokeWidth="1.5"
                  strokeDasharray={CIRC} strokeDashoffset={CIRC * (1 - pct)} strokeLinecap="round"
                  transform="rotate(-90 16 16)"/>
        </svg>
        <span className={refreshing ? "animate-spin text-[#16191f]" : "text-[#16191f]"}>
          <Icon.Refresh/>
        </span>
      </button>
    </div>
  );
}

const FILTERS = [
  { id: "all",             label: "All" },
  { id: "InProgress",      label: "Running" },
  { id: "Failed",          label: "Failed" },
  { id: "recent_failure",  label: "Failed 24h" },
  { id: "Succeeded",       label: "Healthy" },
  { id: "Stopped",         label: "Stopped" },
];
function FilterTabs({ value, onChange, counts }) {
  return (
    <div className="inline-flex rounded-[2px] border border-[#d1d5db] bg-white overflow-hidden">
      {FILTERS.map((f, i) => {
        const active = value === f.id;
        const n = f.id === "all" ? counts.all : counts[f.id] || 0;
        return (
          <button key={f.id} onClick={() => onChange(f.id)}
                  className={`flex items-center gap-1.5 h-8 px-3 text-[13px] transition-colors ${
                    i > 0 ? "border-l border-[#e9ebed]" : ""
                  } ${active ? "bg-[#f1f8fd] text-[#033160] font-semibold" : "text-[#5f6b7a] hover:bg-[#f7f8f8]"}`}>
            {f.label}
            <span className={`font-mono tabular-nums text-[11.5px] ${active ? "text-[#0972d3]" : "text-[#7d8998]"}`}>{n}</span>
          </button>
        );
      })}
    </div>
  );
}

function AwsTopBar() {
  return (
    <div className="bg-[#232f3e] text-[#d5dbdb] h-[44px] flex items-center px-3 gap-3 shrink-0 border-b border-black/30">
      <button className="h-7 w-7 rounded hover:bg-white/10 inline-flex items-center justify-center" aria-label="Menu">
        <svg viewBox="0 0 18 18" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <path d="M3 5h12M3 9h12M3 13h12"/>
        </svg>
      </button>
      <div className="h-6 w-7 rounded bg-white/10 inline-flex items-center justify-center text-[#ff9900] font-bold text-[11px]">CP</div>
      <div className="text-[13px] font-semibold hidden sm:block">AWS CodePulse</div>
      <div className="flex-1"/>
      <div className="hidden sm:block text-[12.5px]">
        <span className="opacity-70">Region:</span> <span className="font-medium">us-east-1</span>
      </div>
      <span className="text-[12.5px] opacity-90 hidden md:inline">dashboard@example</span>
    </div>
  );
}

export default function App() {
  const [accounts, setAccounts] = useState([]);
  const [selectedAccounts, setSelectedAccounts] = useState([]);
  const [pipelines, setPipelines] = useState([]);
  const [lastRefreshed, setLastRefreshed] = useState(Date.now());
  const [secondsLeft, setSecondsLeft] = useState(REFRESH_INTERVAL_MS / 1000);
  const [refreshing, setRefreshing] = useState(true);
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");

  useEffect(() => {
    (async () => {
      const accs = await pipelineService.listAccounts();
      setAccounts(accs);
      setSelectedAccounts(accs.map(a => a.id));
    })();
  }, []);

  const fetchData = useCallback(async (advance = false) => {
    if (selectedAccounts.length === 0) {
      // Empty selection -> show an empty board rather than stale data.
      setPipelines([]);
      setLastRefreshed(Date.now());
      setSecondsLeft(REFRESH_INTERVAL_MS / 1000);
      setRefreshing(false);
      return;
    }
    setRefreshing(true);
    if (advance) pipelineService.advanceMockClock();
    const { pipelines } = await pipelineService.listAllPipelines(selectedAccounts);
    setPipelines(pipelines);
    setLastRefreshed(Date.now());
    setSecondsLeft(REFRESH_INTERVAL_MS / 1000);
    setRefreshing(false);
  }, [selectedAccounts]);

  useEffect(() => { fetchData(false); }, [fetchData]);

  useEffect(() => {
    const id = setInterval(() => {
      setSecondsLeft(s => {
        if (s <= 1) { fetchData(true); return REFRESH_INTERVAL_MS / 1000; }
        return s - 1;
      });
    }, 1000);
    return () => clearInterval(id);
  }, [fetchData]);

  const counts = useMemo(() => {
    const last24h = Date.now() - 24 * 3600 * 1000;
    const c = { all: pipelines.length, Succeeded: 0, Failed: 0, InProgress: 0, Stopped: 0, recent_failure: 0 };
    for (const p of pipelines) {
      c[p.status] = (c[p.status] || 0) + 1;
      const hadFailure = p.status === "Failed"
        || p.history.some(h => h.status === "Failed" && (h.startTime || 0) >= last24h);
      if (hadFailure) c.recent_failure++;
    }
    return c;
  }, [pipelines]);

  const stats = useMemo(() => {
    const total = pipelines.length;
    const running = counts.InProgress || 0;
    const last24h = Date.now() - 24 * 3600 * 1000;
    let failed24 = 0, recentRuns = 0, recentSucc = 0;
    for (const p of pipelines) {
      for (const r of p.history) {
        if ((r.startTime || 0) >= last24h) {
          recentRuns++;
          if (r.status === "Succeeded") recentSucc++;
          if (r.status === "Failed")    failed24++;
        }
      }
      if (p.status === "Failed" && p.lastRunStart >= last24h) failed24++;
    }
    const successRate = recentRuns ? Math.round((recentSucc / recentRuns) * 100) : 100;
    return { total, running, failed24, successRate, recentRuns };
  }, [pipelines, counts]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    const last24h = Date.now() - 24 * 3600 * 1000;
    return pipelines.filter(p => {
      if (filter === "recent_failure") {
        const hadFailure = p.status === "Failed"
          || p.history.some(h => h.status === "Failed" && (h.startTime || 0) >= last24h)
          || (p.lastRunStart >= last24h && p.status === "Failed");
        if (!hadFailure) return false;
      } else if (filter !== "all" && p.status !== filter) {
        return false;
      }
      if (!q) return true;
      return p.name.toLowerCase().includes(q)
          || p.repository.toLowerCase().includes(q)
          || p.version.toLowerCase().includes(q);
    });
  }, [pipelines, filter, query]);

  return (
    <div className="min-h-screen flex flex-col" style={{ background: "#f2f3f3" }}>
      <AwsTopBar/>
      <div className="flex flex-1 min-h-0">
        <main className="flex-1 min-w-0 overflow-auto">
          <header className="px-7 pt-6 pb-3 flex items-center gap-3 flex-wrap">
            <div className="flex items-baseline gap-2 min-w-0">
              <h1 className="text-[22px] font-bold text-[#16191f]">Pipelines</h1>
              <span className={`text-[12.5px] ${C.textSub} ml-2 font-mono tabular-nums`}>
                last refreshed {fmtAbsolute(lastRefreshed)} · next in {secondsLeft}s
              </span>
            </div>
            <div className="flex-1"/>
            <div className="flex items-center gap-2">
              <RefreshControl secondsLeft={secondsLeft} onRefresh={() => fetchData(true)} refreshing={refreshing}/>
              <AccountSwitcher accounts={accounts} selected={selectedAccounts} onChange={setSelectedAccounts}/>
            </div>
          </header>

          <section className="px-7 grid grid-cols-2 lg:grid-cols-4 gap-3">
            <StatCard label="Total pipelines" value={stats.total}
                      active={filter === "all"}
                      onClick={() => setFilter("all")}
                      sub={`across ${selectedAccounts.length} ${selectedAccounts.length === 1 ? "account" : "accounts"}`}/>
            <StatCard label="Currently running" value={stats.running} tone={stats.running ? "blue" : "default"}
                      active={filter === "InProgress"}
                      onClick={() => setFilter(filter === "InProgress" ? "all" : "InProgress")}
                      sub={stats.running ? "live executions" : "no active executions"}/>
            <StatCard label="Failed (last 24h)" value={stats.failed24} tone={stats.failed24 ? "red" : "default"}
                      active={filter === "recent_failure"}
                      onClick={() => setFilter(filter === "recent_failure" ? "all" : "recent_failure")}
                      sub={stats.failed24 ? "click to view failed pipelines" : "all clear"}/>
            <StatCard label="Success rate (24h)" value={`${stats.successRate}%`}
                      tone={stats.successRate >= 90 ? "green" : stats.successRate >= 70 ? "blue" : "red"}
                      active={filter === "Succeeded"}
                      onClick={() => setFilter(filter === "Succeeded" ? "all" : "Succeeded")}
                      sub={`${stats.recentRuns} runs in window`}/>
          </section>

          <section className="px-7 mt-5 mb-3 flex items-center justify-between gap-3 flex-wrap">
            <div className="flex items-center gap-3 flex-wrap">
              <FilterTabs value={filter} onChange={setFilter} counts={counts}/>
              <div className="relative w-[280px] max-w-full">
                <Icon.Search className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#7d8998]"/>
                <input
                  value={query} onChange={e => setQuery(e.target.value)}
                  placeholder="Search pipelines, repos, versions"
                  className="w-full h-8 pl-8 pr-3 rounded-[2px] bg-white text-[#16191f] text-[12.5px] placeholder:text-[#7d8998] outline-none border border-[#7d8998] focus:border-[#0972d3] focus:ring-2 focus:ring-[#0972d3]/20"
                />
              </div>
            </div>
            <span className={`text-[12.5px] font-mono tabular-nums ${C.textSub}`}>
              showing <span className="text-[#16191f]">{visible.length}</span> / {pipelines.length}
            </span>
          </section>

          <section className="px-7 pb-10">
            {pipelines.length === 0 ? (
              <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                {[...Array(6)].map((_, i) => (
                  <div key={i} className="bg-white border border-[#e9ebed] rounded-[2px] h-44 animate-pulse"/>
                ))}
              </div>
            ) : visible.length === 0 ? (
              <div className="py-20 text-center text-[#5f6b7a] text-[13px] bg-white border border-[#e9ebed] rounded-[2px]">
                No pipelines match the current filter.
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                {visible.map(p => <PipelineCard key={p.accountId + "/" + p.name} p={p}/>)}
              </div>
            )}
            <p className={`mt-8 text-[11.5px] font-mono ${C.textMuted}`}>
              Auto-refresh every {REFRESH_INTERVAL_MS / 1000}s · live data via dashboard API
            </p>
          </section>
        </main>
      </div>
      <ChatDrawer pipelines={pipelines} />
    </div>
  );
}
