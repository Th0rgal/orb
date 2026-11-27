import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type JsonObj = Record<string, unknown>;
type McpToolDef = { name: string; description?: string; inputSchema?: JsonObj };

const MUTATING_TOOLS = new Set(["write", "edit"]);
const RAW_LAKE_BUILD_RE = /(^|[;&|(\s])lake\s+(build|exe)\b/;
const READONLY_BASH_FORBIDDEN_RE =
  /(^|[;&|(\s])(rm|mv|cp|mkdir|rmdir|touch|chmod|chown|tee|dd|install|ln|git\s+(add|commit|push|reset|checkout|switch|merge|rebase|clean|stash|apply)|npm\s+install|pnpm\s+(add|install)|cargo\s+build)\b|[>]{1,2}\s*[^&\s]/;

function sanitizeToolName(prefix: string, name: string): string {
  return `${prefix}__${name.replace(/[^A-Za-z0-9_.-]/g, "_")}`;
}

function normalizeSchema(raw?: JsonObj): JsonObj {
  if (raw && typeof raw === "object" && raw.type === "object") return raw;
  return { type: "object", properties: {}, additionalProperties: true };
}

function formatMcpContent(result: unknown): { content: Array<{ type: "text"; text: string }>; details: unknown } {
  const obj = (result && typeof result === "object" ? result : {}) as JsonObj;
  const items = Array.isArray(obj.content) ? obj.content : [];
  const texts: string[] = [];
  for (const it of items) {
    if (it && typeof it === "object" && typeof (it as JsonObj).text === "string") {
      texts.push((it as JsonObj).text as string);
    }
  }
  const text = texts.length > 0 ? texts.join("\n") : JSON.stringify(result ?? {});
  return { content: [{ type: "text", text }], details: result ?? {} };
}

async function httpMcpRpc(url: string, token: string, body: JsonObj, sessionId?: string): Promise<{ data: JsonObj | null; sessionId?: string }> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${token}`,
  };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  const resp = await fetch(url, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(60_000) });
  const nextSession = resp.headers.get("mcp-session-id") ?? sessionId;
  if (resp.status === 202) return { data: null, sessionId: nextSession };
  const text = await resp.text();
  if (!resp.ok) throw new Error(`MCP HTTP ${resp.status}: ${text.slice(0, 300)}`);
  const ctype = resp.headers.get("content-type") ?? "";
  if (ctype.includes("text/event-stream")) {
    let last: JsonObj | null = null;
    for (const ln of text.split("\n")) {
      const t = ln.trim();
      if (t.startsWith("data:")) {
        const payload = t.slice(5).trim();
        if (payload && payload !== "[DONE]") last = JSON.parse(payload) as JsonObj;
      }
    }
    return { data: last, sessionId: nextSession };
  }
  return { data: text.trim() ? (JSON.parse(text) as JsonObj) : null, sessionId: nextSession };
}

class StdioMcpClient {
  private proc: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private buf = "";
  private pending = new Map<number, { resolve: (v: JsonObj) => void; reject: (e: Error) => void }>();

  constructor(bin: string, args: string[]) {
    this.proc = spawn(bin, args, { stdio: ["pipe", "pipe", "ignore"] });
    this.proc.stdout.setEncoding("utf8");
    this.proc.stdout.on("data", (chunk: string) => {
      this.buf += chunk;
      let idx: number;
      while ((idx = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, idx).replace(/\r$/, "").trim();
        this.buf = this.buf.slice(idx + 1);
        if (!line) continue;
        try {
          const msg = JSON.parse(line) as JsonObj;
          const id = typeof msg.id === "number" ? msg.id : -1;
          const slot = this.pending.get(id);
          if (slot) {
            this.pending.delete(id);
            if (msg.error) slot.reject(new Error(JSON.stringify(msg.error)));
            else slot.resolve((msg.result ?? {}) as JsonObj);
          }
        } catch {
          /* ignore non-JSON stderr/banner lines */
        }
      }
    });
    this.proc.on("exit", () => {
      for (const [, slot] of this.pending) slot.reject(new Error("turbo-lean mcp exited"));
      this.pending.clear();
    });
  }

  request(method: string, params: JsonObj): Promise<JsonObj> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`turbo-lean mcp timeout on ${method}`));
      }, 30_000);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  notify(method: string, params?: JsonObj): void {
    this.proc.stdin.write(`${JSON.stringify(params ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", method })}\n`);
  }

  close(): void {
    try { this.proc.stdin.end(); } catch { /* noop */ }
    try { this.proc.kill("SIGTERM"); } catch { /* noop */ }
  }
}

export default async function orbExtension(pi: ExtensionAPI): Promise<void> {
  pi.registerFlag("plan", { description: "Run Pi in Orb read-only plan mode", type: "boolean", default: false });

  const isReadOnly = () =>
    process.env.ORB_PI_READONLY === "1" || process.env.ORB_PI_PLAN === "1" || Boolean(pi.getFlag("plan"));
  const registeredMcpTools: string[] = [];
  let turboClient: StdioMcpClient | null = null;

  // 1. Sandboxed Streamable HTTP MCP bridge
  const mcpUrl =
    process.env.SANDBOXED_MCP_URL?.trim() ||
    (process.env.SANDBOXED_MCP_API_URL?.trim() ? `${process.env.SANDBOXED_MCP_API_URL.replace(/\/+$/, "")}/api/mcp/rpc` : "");
  const mcpToken = process.env.SANDBOXED_MCP_TOKEN?.trim() || "";
  if (mcpUrl && mcpToken) {
    try {
      let sid: string | undefined;
      let reqId = 1;
      const init = await httpMcpRpc(mcpUrl, mcpToken, {
        jsonrpc: "2.0",
        id: reqId++,
        method: "initialize",
        params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "orb-pi-extension", version: "0.1.0" } },
      });
      sid = init.sessionId;
      await httpMcpRpc(mcpUrl, mcpToken, { jsonrpc: "2.0", method: "notifications/initialized" }, sid).catch(() => undefined);
      const list = await httpMcpRpc(mcpUrl, mcpToken, { jsonrpc: "2.0", id: reqId++, method: "tools/list", params: {} }, sid);
      const tools = ((list.data?.result as JsonObj | undefined)?.tools as McpToolDef[] | undefined) ?? [];
      for (const tool of tools) {
        const regName = sanitizeToolName("sandboxed", tool.name);
        registeredMcpTools.push(regName);
        pi.registerTool({
          name: regName,
          label: `sandboxed:${tool.name}`,
          description: tool.description || `Orb MCP tool ${tool.name}`,
          parameters: normalizeSchema(tool.inputSchema) as never,
          async execute(_callId, params) {
            const call = await httpMcpRpc(mcpUrl, mcpToken, {
              jsonrpc: "2.0",
              id: reqId++,
              method: "tools/call",
              params: { name: tool.name, arguments: params ?? {} },
            }, sid);
            if (call.data?.error) throw new Error(JSON.stringify(call.data.error));
            return formatMcpContent(call.data?.result);
          },
        });
      }
    } catch {
      /* fail-open on unavailable optional MCP discovery; OrbCore tracks MCP health separately */
    }
  }

  // 2. turbo-lean stdio MCP bridge (auto-enabled whenever turbo-lean is available)
  if (process.env.ORB_PI_DISABLE_TURBO_LEAN_MCP !== "1") {
    const turboBin = process.env.ORB_TURBO_LEAN_BIN?.trim() || "turbo-lean";
    try {
      const client = new StdioMcpClient(turboBin, ["mcp"]);
      await client.request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "orb-pi-extension", version: "0.1.0" },
      });
      client.notify("notifications/initialized");
      const list = await client.request("tools/list", {});
      const tools = (list.tools as McpToolDef[] | undefined) ?? [];
      turboClient = client;
      for (const tool of tools) {
        const regName = sanitizeToolName("turbo_lean", tool.name);
        registeredMcpTools.push(regName);
        pi.registerTool({
          name: regName,
          label: `turbo-lean:${tool.name}`,
          description: tool.description || `turbo-lean MCP tool ${tool.name}`,
          parameters: normalizeSchema(tool.inputSchema) as never,
          async execute(_callId, params) {
            const res = await client.request("tools/call", { name: tool.name, arguments: params ?? {} });
            return formatMcpContent(res);
          },
        });
      }
    } catch {
      turboClient?.close();
      turboClient = null;
    }
  }

  pi.on("session_start", () => {
    const base = isReadOnly() ? ["read", "grep", "find", "ls"] : ["read", "bash", "edit", "write", "grep", "find", "ls"];
    const allowedMcp = isReadOnly()
      ? registeredMcpTools.filter((n) => n.startsWith("turbo_lean__") || n.includes("read") || n.includes("get_") || n.includes("list_") || n.includes("search"))
      : registeredMcpTools;
    pi.setActiveTools([...base, ...allowedMcp]);
  });

  pi.on("tool_call", (event) => {
    const ro = isReadOnly();
    if (ro && MUTATING_TOOLS.has(event.toolName)) {
      return { block: true, reason: `Tool '${event.toolName}' is disabled in Orb read-only/plan mode.` };
    }
    if (event.toolName === "bash") {
      const cmd = typeof (event.input as JsonObj)?.command === "string" ? String((event.input as JsonObj).command) : "";
      if (ro && READONLY_BASH_FORBIDDEN_RE.test(cmd)) {
        return { block: true, reason: "Mutating bash commands are disabled in Orb read-only/plan mode." };
      }
      if (RAW_LAKE_BUILD_RE.test(cmd) && !cmd.includes("SANDBOXED_ALLOW_RAW_LAKE=1") && process.env.SANDBOXED_ALLOW_RAW_LAKE !== "1") {
        return {
          block: true,
          reason: "Direct `lake build` is blocked by Orb FV policy. Use `turbo-lean` (or `turbo_lean__*` MCP tools), or set SANDBOXED_ALLOW_RAW_LAKE=1 for explicit fallback.",
        };
      }
    }
  });

  pi.on("session_shutdown", () => {
    turboClient?.close();
    turboClient = null;
  });
}
