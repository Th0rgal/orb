/** Records why the app felt slow: stalls of the page's thread, slow requests,
 * stream load and a window the page does not fill. Entries are appended to
 * `~/.orb/logs/orb-<date>.jsonl` by the native side, which also notices when
 * the page stops reporting at all. */

type Invoke = (command: string, args?: Record<string, unknown>) => Promise<unknown>;
type Entry = { at: string; kind: string } & Record<string, unknown>;

const STALL_MS = 250, HIDDEN_STALL_MS = 2500, BEAT_MS = 500, FLUSH_MS = 5000, SUMMARY_MS = 30_000, SLOW_REQUEST_MS = 2000, SLOW_WORK_MS = 50;
const KEPT = 500;

const pending: Entry[] = [];
const recent: Entry[] = [];
const work = new Map<string, { calls: number; ms: number; worst: number }>();
const requests = { count: 0, failed: 0, ms: 0, worst: 0, worstPath: "" };
const routes = new Map<string, { count: number; ms: number }>();
const streams = new Map<string, { events: number; bytes: number }>();
let stalls = { count: 0, ms: 0, worst: 0 };
let started = false;

const invoke = (): Invoke | undefined => {
  const g = window as unknown as { __TAURI__?: { core?: { invoke?: Invoke } }; __TAURI_INTERNALS__?: { invoke?: Invoke } };
  return g.__TAURI__?.core?.invoke ?? g.__TAURI_INTERNALS__?.invoke;
};
const round = (value: number) => Math.round(value);
const view = () => `${location.pathname}${location.hash}`.slice(0, 120);

export function note(kind: string, data: Record<string, unknown> = {}): void {
  const entry: Entry = { at: new Date().toISOString(), kind, view: view(), ...data };
  pending.push(entry);
  recent.push(entry);
  if (recent.length > KEPT) recent.splice(0, recent.length - KEPT);
  if (pending.length > KEPT) pending.splice(0, pending.length - KEPT);
}

/** Time a synchronous piece of work that may hold the page's thread. */
export function timed<T>(name: string, run: () => T): T {
  const from = performance.now();
  try { return run(); } finally {
    const ms = performance.now() - from;
    const row = work.get(name) ?? { calls: 0, ms: 0, worst: 0 };
    row.calls++; row.ms += ms; row.worst = Math.max(row.worst, ms);
    work.set(name, row);
    if (ms >= SLOW_WORK_MS) note("slow-work", { name, ms: round(ms) });
  }
}

export function requestDone(path: string, ms: number, ok: boolean, detail?: string): void {
  requests.count++; requests.ms += ms;
  // Ids are kept for single-mission reads: which missions are re-read, and
  // by what, is the question that route alone cannot answer.
  const route = path.split("?")[0].replace(/[0-9a-f]{8}-[0-9a-f-]{27}(?!\/)/g, id => id.slice(0, 8)).replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, ":id");
  const row = routes.get(route) ?? { count: 0, ms: 0 };
  row.count++; row.ms += ms;
  routes.set(route, row);
  if (!ok) requests.failed++;
  if (ms > requests.worst) { requests.worst = ms; requests.worstPath = path; }
  if (ms >= SLOW_REQUEST_MS || !ok) note(ok ? "slow-request" : "failed-request", { path: path.slice(0, 160), ms: round(ms), ...(detail ? { detail: detail.slice(0, 200) } : {}) });
}

export function streamLoad(stream: string, events: number, bytes: number): void {
  const row = streams.get(stream) ?? { events: 0, bytes: 0 };
  row.events += events; row.bytes += bytes;
  streams.set(stream, row);
}

/** The page should fill the window. When it does not, part of the window
 * shows whatever is behind it. */
async function checkWindow(): Promise<void> {
  const root = document.getElementById("root")?.getBoundingClientRect();
  const page = { width: window.innerWidth, height: window.innerHeight, ratio: window.devicePixelRatio };
  const shape: Record<string, unknown> = { page, document: { width: document.documentElement.clientWidth, height: document.documentElement.clientHeight }, root: root && { width: round(root.width), height: round(root.height) } };
  let wrong = !!root && (root.height < page.height - 2 || root.width < page.width - 2);
  try {
    const native = (window as unknown as { __TAURI__?: { window?: { getCurrentWindow?: () => { innerSize: () => Promise<{ width: number; height: number }>; scaleFactor: () => Promise<number> } } } }).__TAURI__?.window?.getCurrentWindow?.();
    if (native) {
      const [size, scale] = await Promise.all([native.innerSize(), native.scaleFactor()]);
      const expected = { width: round(size.width / scale), height: round(size.height / scale) };
      shape.window = expected;
      if (Math.abs(expected.height - page.height) > 2 || Math.abs(expected.width - page.width) > 2) wrong = true;
    }
  } catch { /* outside the desktop app there is no window to compare with */ }
  // While the window is being resized the two sizes are read at different
  // moments; only a difference that lasts is a fault.
  const seen = JSON.stringify(shape);
  if (wrong && lastMismatch === seen) note("window-mismatch", shape);
  lastMismatch = wrong ? seen : "";
  if (wrong) { clearTimeout(recheck); recheck = setTimeout(() => void checkWindow(), 1500); }
}
let lastMismatch = "", recheck: ReturnType<typeof setTimeout> | undefined;

function summary(): void {
  const busiest = [...work].sort((a, b) => b[1].ms - a[1].ms).slice(0, 8).map(([name, row]) => ({ name, calls: row.calls, ms: round(row.ms), worst: round(row.worst) }));
  const live = [...streams].map(([stream, row]) => ({ stream, ...row }));
  note("summary", {
    seconds: SUMMARY_MS / 1000,
    hidden: document.hidden,
    stalls: { count: stalls.count, ms: round(stalls.ms), worst: round(stalls.worst) },
    requests: { count: requests.count, failed: requests.failed, ms: round(requests.ms), worst: round(requests.worst), worstPath: requests.worstPath.slice(0, 160) },
    routes: [...routes].sort((a, b) => b[1].count - a[1].count).slice(0, 10).map(([route, row]) => ({ route, count: row.count, ms: round(row.ms) })),
    streams: live,
    work: busiest,
    nodes: document.getElementsByTagName("*").length,
  });
  work.clear(); streams.clear(); routes.clear();
  stalls = { count: 0, ms: 0, worst: 0 };
  requests.count = requests.failed = requests.ms = requests.worst = 0; requests.worstPath = "";
}

async function flush(): Promise<void> {
  const send = invoke();
  // The call doubles as the sign of life the native side waits for.
  const lines = pending.splice(0).map(entry => JSON.stringify(entry));
  if (!send) return;
  try { await send("diagnostics_append", { lines }); } catch { /* an older native build has no log */ }
}

export function startDiagnostics(): void {
  if (started || typeof window === "undefined") return;
  started = true;
  (window as unknown as { orbDiagnostics?: unknown }).orbDiagnostics = { recent: () => recent.slice(), flush };
  note("started", { agent: navigator.userAgent.slice(0, 160) });

  let expected = performance.now() + BEAT_MS;
  setInterval(() => {
    const now = performance.now(), late = now - expected;
    expected = now + BEAT_MS;
    // A hidden page has its timers slowed to about one per second.
    if (late < (document.hidden ? HIDDEN_STALL_MS : STALL_MS)) return;
    stalls.count++; stalls.ms += late; stalls.worst = Math.max(stalls.worst, late);
    note("stall", { ms: round(late), hidden: document.hidden });
    if (late >= 1000) void flush();
  }, BEAT_MS);

  // A frame that takes long to arrive while the thread is free points at
  // painting rather than at scripts.
  setInterval(() => {
    if (document.hidden) return;
    const asked = performance.now();
    requestAnimationFrame(() => {
      const waited = performance.now() - asked;
      if (waited >= STALL_MS) note("slow-frame", { ms: round(waited) });
    });
  }, 2000);

  setInterval(summary, SUMMARY_MS);
  setInterval(() => void flush(), FLUSH_MS);
  setInterval(() => void checkWindow(), 10_000);
  let resized: ReturnType<typeof setTimeout> | undefined;
  window.addEventListener("resize", () => { clearTimeout(resized); resized = setTimeout(() => void checkWindow(), 1000); });
  window.addEventListener("error", event => note("error", { message: String(event.message).slice(0, 300), source: `${event.filename}:${event.lineno}` }));
  window.addEventListener("unhandledrejection", event => note("rejection", { message: String(event.reason).slice(0, 300) }));
  document.addEventListener("visibilitychange", () => note("visibility", { hidden: document.hidden }));
}
