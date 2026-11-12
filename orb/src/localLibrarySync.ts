import {
  api,
  getApiUrl,
  isConnected,
  type LibrarySkill,
  type LibrarySkillSummary,
} from "./api";
import { ApprovalCancelled, signedApi } from "./deviceApproval";
import {
  desktopInvoke,
  type LocalSkillsReport,
  type McpSessionPayload,
  type SyncSkillPayload,
  type SyncSkillsResult,
} from "./localAgents";
import { rememberSkillsReport } from "./skillCache";
import {
  fetchLibrarySkill,
  readSkillFile,
  rememberKnownSkillNames,
} from "./skillsApi";

const mcpMintDismissedFor = new Set<string>();
const mcpMintFailedFor = new Map<string, string>();
let mcpMintInFlight: Promise<{ session?: McpSessionPayload; error?: string }> | null = null;

function normalizedConnectedApiUrl(): string {
  return isConnected() ? getApiUrl().trim().replace(/\/+$/, "") : "";
}

async function mintLocalMcpSessionIfNeeded(
  invoke: NonNullable<ReturnType<typeof desktopInvoke>>,
  apiUrl: string,
  forcePrompt = false,
): Promise<{ session?: McpSessionPayload; error?: string }> {
  if (!apiUrl) return {};
  if (forcePrompt) {
    mcpMintDismissedFor.delete(apiUrl);
    mcpMintFailedFor.delete(apiUrl);
  }
  const status = (await invoke("local_skills_status", {
    request: { library_skills: [], api_url: apiUrl },
  }).catch(() => null)) as LocalSkillsReport | null;
  if (status?.mcp?.needs_token !== true) return {};
  if (!forcePrompt && (mcpMintDismissedFor.has(apiUrl) || mcpMintFailedFor.has(apiUrl))) {
    return { error: mcpMintFailedFor.get(apiUrl) };
  }
  if (mcpMintInFlight) return mcpMintInFlight;
  mcpMintInFlight = (async () => {
    try {
      const minted = await signedApi<{
        token: string;
        session_id: string;
        expires_at?: number;
        hard_expires_at?: number;
        role?: string;
      }>(
        "POST",
        "/api/mcp/external-sessions",
        {
          role: "coordinator",
          client_kind: "local_mcp",
          client_label: "Local Harnesses",
          ttl_days: 30,
        },
        "Mint coordinator MCP session for local harnesses (30d)",
      );
      mcpMintFailedFor.delete(apiUrl);
      mcpMintDismissedFor.delete(apiUrl);
      return {
        session: {
          api_url: apiUrl,
          token: minted.token,
          session_id: minted.session_id,
          role: minted.role ?? "coordinator",
          expires_at: minted.expires_at,
          hard_expires_at: minted.hard_expires_at,
        },
      };
    } catch (error) {
      if (error instanceof ApprovalCancelled) {
        mcpMintDismissedFor.add(apiUrl);
        return {};
      }
      const msg = error instanceof Error ? error.message : String(error);
      mcpMintFailedFor.set(apiUrl, msg);
      return { error: msg };
    }
  })().finally(() => {
    mcpMintInFlight = null;
  });
  return mcpMintInFlight;
}

/** Inspect local harnesses against the given Library snapshot (canonical source). */
export async function localSkillsStatus(
  librarySkills?: SyncSkillPayload[],
  libraryLoaded = false,
): Promise<LocalSkillsReport | null> {
  const invoke = desktopInvoke();
  if (!invoke) return null;
  const apiUrl = normalizedConnectedApiUrl();
  const hasSkills = Boolean(librarySkills && librarySkills.length > 0);
  return (await invoke("local_skills_status", {
    request: {
      library_skills: librarySkills ?? [],
      ...(libraryLoaded || hasSkills ? { library_loaded: true } : {}),
      ...(apiUrl ? { api_url: apiUrl } : {}),
    },
  })) as LocalSkillsReport;
}

export async function localSkillsSync(
  options: {
    librarySkills?: SyncSkillPayload[];
    libraryLoaded?: boolean;
    pruneRemoved?: boolean;
    replaceUnmanaged?: string[];
    mcpSession?: McpSessionPayload;
    forceMcpPrompt?: boolean;
    skipMcpMint?: boolean;
  } = {},
): Promise<SyncSkillsResult> {
  const invoke = desktopInvoke();
  if (!invoke) throw new Error("Unified local skill sync requires the Orb desktop app.");
  const apiUrl = normalizedConnectedApiUrl();
  let mcpSession = options.mcpSession;
  let mintError: string | undefined;
  if (!mcpSession && !options.skipMcpMint && apiUrl) {
    const minted = await mintLocalMcpSessionIfNeeded(invoke, apiUrl, options.forceMcpPrompt);
    mcpSession = minted.session;
    mintError = minted.error;
  }
  const hasSkills = Boolean(options.librarySkills && options.librarySkills.length > 0);
  const result = (await invoke("local_skills_sync", {
    request: {
      library_skills: options.librarySkills ?? [],
      ...(options.libraryLoaded || hasSkills ? { library_loaded: true } : {}),
      prune_removed: options.pruneRemoved ?? false,
      replace_unmanaged: options.replaceUnmanaged ?? [],
      ...(apiUrl ? { api_url: apiUrl } : {}),
      ...(mcpSession ? { mcp_session: mcpSession } : {}),
    },
  })) as SyncSkillsResult;
  if (!result.mcp_error && mintError) {
    return { ...result, mcp_error: mintError };
  }
  return result;
}

/** Build a complete `SyncSkillPayload` (including any non-inline companion files) for one Library skill. */
export async function skillToSyncPayload(
  skill: LibrarySkill,
  summary?: LibrarySkillSummary,
): Promise<SyncSkillPayload> {
  const inlineFiles = (skill.files ?? [])
    .filter((f) => (f.path || f.name) !== "SKILL.md")
    .map((f) => ({ rel: f.path || f.name, content: f.content }));
  const missingRefs = (skill.references ?? []).filter(
    (r) => r && r !== "SKILL.md" && !inlineFiles.some((f) => f.rel === r),
  );
  const extraFiles = await Promise.all(
    missingRefs.map(async (rel) => ({
      rel,
      content: await readSkillFile(skill.name, rel).catch(() => ""),
    })),
  );
  return {
    name: skill.name,
    content: skill.content,
    files: [...inlineFiles, ...extraFiles],
    audience: skill.audience ?? summary?.audience ?? null,
    scope: skill.scope ?? summary?.scope ?? null,
  };
}

/** Fetch all Library skills ready for `local_skills_sync`, using `?include=bundle` when supported. */
export async function fetchLibrarySyncPayloads(): Promise<{
  payloads: SyncSkillPayload[];
  loaded: boolean;
}> {
  if (!isConnected()) return { payloads: [], loaded: false };
  const raw = await api<Array<LibrarySkillSummary & Partial<LibrarySkill>>>(
    "/api/library/skill?include=bundle",
  ).catch(() => api<Array<LibrarySkillSummary & Partial<LibrarySkill>>>("/api/library/skill"));
  if (!Array.isArray(raw)) return { payloads: [], loaded: false };
  rememberKnownSkillNames(raw.map((s) => s.name));
  const payloads: SyncSkillPayload[] = [];
  await Promise.all(
    raw.map(async (item) => {
      if (!item?.name) return;
      const full: LibrarySkill | null =
        typeof item.content === "string"
          ? ({ ...item, content: item.content } as LibrarySkill)
          : await fetchLibrarySkill(item.name).catch(() => null);
      if (!full) return;
      payloads.push(await skillToSyncPayload(full, item));
    }),
  );
  payloads.sort((a, b) => a.name.localeCompare(b.name));
  return { payloads, loaded: true };
}

/** Sync the connected Core Library (and MCP wiring) to local harnesses (`antigravity`, `opencode`, `claudecode`, etc.). */
export async function syncConnectedLibraryToLocalHarnesses(options: {
  pruneRemoved?: boolean;
  replaceUnmanaged?: string[];
  skipMcpMint?: boolean;
  onlyIfNeeded?: boolean;
  fallbackSkill?: LibrarySkill;
} = {}): Promise<SyncSkillsResult | null> {
  if (!desktopInvoke()) return null;
  let payloads: SyncSkillPayload[] = [];
  let loaded = false;
  if (isConnected()) {
    try {
      const fetched = await fetchLibrarySyncPayloads();
      payloads = fetched.payloads;
      loaded = fetched.loaded;
    } catch {
      loaded = false;
    }
  }
  if (!loaded && options.fallbackSkill) {
    payloads = [await skillToSyncPayload(options.fallbackSkill)];
  } else if (loaded && options.fallbackSkill) {
    const updated = await skillToSyncPayload(options.fallbackSkill);
    const idx = payloads.findIndex((p) => p.name === updated.name);
    if (idx >= 0) payloads[idx] = updated;
    else payloads.push(updated);
  }
  const prune = Boolean(options.pruneRemoved && loaded);
  if (options.onlyIfNeeded) {
    const rep = await localSkillsStatus(payloads, loaded);
    if (!rep) return null;
    if (loaded) {
      rememberSkillsReport(rep);
      rememberKnownSkillNames(rep.skills.map((s) => s.name));
    }
    const hasSkillDrift =
      loaded &&
      rep.harnesses.some(
        (h) =>
          (h.canonical_total > 0 && h.synced_count < h.canonical_total) ||
          (prune && (h.stale_managed?.length ?? 0) > 0),
      );
    const hasMcpDrift = Boolean(rep.mcp?.ready && rep.mcp.missing_harnesses.length > 0);
    if (!hasSkillDrift && !hasMcpDrift) return null;
  }
  const res = await localSkillsSync({
    librarySkills: payloads,
    libraryLoaded: loaded,
    pruneRemoved: prune,
    replaceUnmanaged: options.replaceUnmanaged,
    skipMcpMint: options.skipMcpMint,
  });
  if (loaded && res?.report) {
    rememberSkillsReport(res.report);
    rememberKnownSkillNames(res.report.skills.map((s) => s.name));
  }
  return res;
}
