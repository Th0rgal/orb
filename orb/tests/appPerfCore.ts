// A mock Core for whole-app performance runs: ~20 projects, ~100 missions,
// one long mission (hundreds of events with tools, markdown, code and a
// diagram) and a live SSE stream the test can push text deltas into.
import http from 'node:http';
import type {AddressInfo} from 'node:net';

/** A well-formed (unsigned) token, so code that reads its claims takes the normal path. */
export const JWT = `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify({sub: 'perf', exp: 4102444800})).toString('base64url')}.sig`;
export const LONG = 'aaaaaaaa-0000-4000-8000-000000000000';
const uuid = (n: number) => `bbbbbbbb-0000-4000-8000-${String(n).padStart(12, '0')}`;

export function projects() {
 return Array.from({length: 20}, (_, i) => ({slug: `p${i}`, title: `Project ${i}`}));
}
export function missions() {
 const rows = Array.from({length: 100}, (_, i) => ({
  id: i === 0 ? LONG : uuid(i), title: i === 0 ? 'Long mission' : `Mission ${i} doing some work`, backend: 'claudecode',
  project: `p${i % 20}`, status: i < 8 ? 'active' : 'completed', history: [],
  created_at: new Date(Date.UTC(2026, 9, 1) + i * 60000).toISOString(),
  updated_at: new Date(Date.UTC(2026, 9, 20) + i * 60000).toISOString(),
 }));
 return rows;
}

const md = (n: number) => `## Step ${n}\n\nI looked at **module ${n}** and found that \`fn_${n}\` handles the edge case. A few notes:\n\n- the cache is keyed by path\n- writes go through \`commit()\`\n- see [docs](https://example.com/${n})\n\n\`\`\`ts\nexport function fn_${n}(x: number) {\n  return x * ${n} + 1;\n}\n\`\`\`\n\nThe change keeps behaviour identical.`;
const mermaid = '```mermaid\ngraph TD\n  A[Start] --> B{Check}\n  B -->|yes| C[Done]\n  B -->|no| A\n```';

/** `turns` user turns, each with tool calls/results and a markdown answer. */
export function longEvents(turns = 60) {
 const out: Record<string, unknown>[] = [];
 let seq = 0;
 const push = (event_type: string, content: string, extra: Record<string, unknown> = {}) => {
  seq++;
  out.push({id: seq, sequence: seq, event_id: `e${seq}`, event_type, content, timestamp: new Date(Date.UTC(2026, 9, 20) + seq * 1000).toISOString(), ...extra});
 };
 for (let t = 0; t < turns; t++) {
  push('user_message', `Please inspect module ${t} and fix what is broken.`);
  for (let k = 0; k < 4; k++) {
   const id = `call-${t}-${k}`;
   push('tool_call', JSON.stringify({command: `rg -n fn_${t} src/ | head -${k + 5}`}), {tool_call_id: id, tool_name: 'Bash'});
   push('tool_result', `src/mod_${t}.rs:${k}: fn fn_${t}() {}\n`.repeat(6), {tool_call_id: id, tool_name: 'Bash'});
  }
  push('assistant_message', md(t) + (t % 15 === 0 ? `\n\n${mermaid}` : ''));
 }
 return out;
}

type Stream = {res: http.ServerResponse};
export type Core = {url: string; counts: Map<string, number>; unknown: Set<string>; push: (event: string, data: unknown) => void; close: () => Promise<void>};

export async function startCore(events = longEvents()): Promise<Core> {
 const counts = new Map<string, number>(), unknown = new Set<string>(), streams: Stream[] = [];
 const ms = missions(), ps = projects();
 const json = (res: http.ServerResponse, body: unknown, headers: Record<string, string> = {}) => {
  res.writeHead(200, {'Content-Type': 'application/json', ...headers}); res.end(JSON.stringify(body));
 };
 const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', '*');
  res.setHeader('Access-Control-Expose-Headers', 'X-Orb-Events-Protocol, X-Has-More, X-Max-Sequence, X-Next-Cursor, X-Page-Max-Sequence');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  const url = new URL(req.url!, 'http://x'), path = url.pathname;
  const key = path.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, ':id');
  counts.set(key, (counts.get(key) ?? 0) + 1);
  if (path === '/api/control/stream') {
   res.writeHead(200, {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache'});
   res.write(': open\n\n');
   const s = {res}; streams.push(s);
   req.on('close', () => streams.splice(streams.indexOf(s), 1));
   return;
  }
  if (path.endsWith('/events')) {
   const id = path.split('/')[4];
   const rows = id === LONG ? events : [];
   const since = url.searchParams.get('since_seq'), before = url.searchParams.get('before_seq');
   let page = rows.filter(e => (since === null || (e.sequence as number) > Number(since)) && (before === null || (e.sequence as number) < Number(before)));
   const limit = Number(url.searchParams.get('limit') ?? 200);
   const more = page.length > limit;
   page = since !== null ? page.slice(0, limit) : page.slice(-limit);
   const seqs = page.map(e => e.sequence as number);
   const headers: Record<string, string> = {'X-Orb-Events-Protocol': '1', 'X-Has-More': String(more), 'X-Max-Sequence': String(rows.length)};
   if (seqs.length) { headers['X-Page-Max-Sequence'] = String(Math.max(...seqs)); headers['X-Next-Cursor'] = String(since === null ? Math.min(...seqs) : Math.max(...seqs)); }
   return json(res, page, headers);
  }
  const project = url.searchParams.get('project');
  if (path === '/api/projects') return json(res, {projects: ps});
  if (path === '/api/control/missions') return json(res, project ? ms.filter(m => m.project === project) : ms);
  if (path.startsWith('/api/control/missions/') && path.split('/').length === 5) return json(res, ms.find(m => m.id === path.split('/')[4]) ?? ms[0]);
  if (path.endsWith('/files')) return json(res, {entries: []});
  if (path.endsWith('/crons')) return json(res, {jobs: []});
  if (path.includes('/controller')) return json(res, {job: null, runs: []});
  if (path === '/api/providers/backend-models') return json(res, {backends: {}});
  if (/queue|backends|remote-nodes|automations|approval/.test(path)) return json(res, path.includes('approval') ? {items: []} : []);
  unknown.add(key);
  return json(res, {});
 });
 await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
 return {
  url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, counts, unknown,
  push: (event, data) => { for (const s of streams) s.res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); },
  close: () => { for (const s of streams) s.res.end(); server.closeAllConnections(); return new Promise(r => server.close(() => r())); },
 };
}
