import { api, ApiError, createMission, type Mission } from './api';
export type CloudProvider = 'grok_bot' | 'cursor_cloud' | 'hermes';
export const cloudNames: Record<CloudProvider, string> = { grok_bot: 'Grok Bot', cursor_cloud: 'Cursor Cloud', hermes: 'Hermes' };
export interface ModelParam {id:string;value:string}
export interface CloudSelection { model_params?: ModelParam[]; provider: CloudProvider; account: string; repository?: string; git_ref?: string; model?: string }
export interface CloudAccount { id: string; provider: CloudProvider; label: string; available: boolean; experimental: boolean; reason?: string; capabilities: { models: boolean; repository: boolean; attachments: boolean; follow_up: boolean; cancel: boolean; artifacts: boolean; detailed_events: boolean } }
export interface CloudTurnStep { id?: string; kind: 'think' | 'tool'; text?: string; call_id?: string; name?: string; status?: string; input?: unknown; output?: unknown; args?: unknown; result?: unknown; error?: string; done?: boolean; duration?: number }
export interface CloudTurn { model?:string; model_params?: ModelParam[]; key: string; prompt: string; phase: string; external_id?: string; result?: string; detail?: string; steps?: CloudTurnStep[]; artifacts: { kind?: string; run_id?:string; request?:{request_id?:string;command?:string;choices?:string[]}; path: string; sizeBytes?: number }[]; branches: { branch?: string; prUrl?: string }[]; usage?: unknown }
export interface CloudExecution { mission_id: string; revision: number; selection: CloudSelection; external_url?: string; turns: CloudTurn[] }
export interface HermesSettingsState {
  home_dir: string;
  config_path: string;
  soul_path: string;
  default_model: string;
  provider: string;
  base_url: string;
  reasoning_effort: string;
  use_sandboxed_router: boolean;
  memory_enabled: boolean;
  user_profile_enabled: boolean;
  memory_char_limit: number;
  user_char_limit: number;
  compression_enabled: boolean;
  compression_threshold: number;
  telegram_tool_progress: string;
  telegram_cleanup_progress: boolean;
  soul_markdown: string;
  runtime: {
    installed?: boolean;
    service_name?: string;
    service_state?: string | null;
    gateway_state?: string | null;
    gateway_pid?: number | null;
    updated_at?: string | null;
    api_server_enabled?: boolean;
    api_server_url?: string;
    api_server_healthy?: boolean;
    active_runs?: number;
    service_active?: boolean;
    model?: string;
    base_url?: string;
    uses_sandboxed_proxy?: boolean;
    token_present?: boolean;
    notes?: string[];
  };
  sessions: {
    available?: boolean;
    total_sessions?: number;
    active_sessions_24h?: number;
    total_tokens?: number;
  };
  models: { id: string; name?: string; displayName?: string; kind?: string }[];
  efforts: { id: string; name?: string; displayName?: string }[];
}
export interface HermesSettingsPatch {
  default_model?: string;
  reasoning_effort?: string;
  use_sandboxed_router?: boolean;
  memory_enabled?: boolean;
  user_profile_enabled?: boolean;
  memory_char_limit?: number;
  user_char_limit?: number;
  compression_enabled?: boolean;
  compression_threshold?: number;
  telegram_tool_progress?: string;
  telegram_cleanup_progress?: boolean;
  soul_markdown?: string;
  restart_service?: boolean;
}
export async function cloudAccounts(): Promise<CloudAccount[]> { try { return await api<CloudAccount[]>('/api/cloud/accounts'); } catch (error) { if (error instanceof ApiError && error.status === 404) throw new Error('Cloud agents are not available on this Core yet. Core needs the cloud agent update.'); throw error; } }
export const cloudExecution = (id: string) => api<CloudExecution>(`/api/control/missions/${encodeURIComponent(id)}/cloud`);
export const getHermesSettings = () => api<HermesSettingsState>('/api/cloud/hermes/settings');
export const updateHermesSettings = (patch: HermesSettingsPatch) => api<HermesSettingsState>('/api/cloud/hermes/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(patch) });
export function cloudPhase(phase: string): string { return ({ queued: 'Queued', submitting: 'Starting', submission_uncertain: 'Submission needs verification', running: 'Working', waiting_user: 'Waiting for your reply', reconnect_required: 'Reconnect account', response_complete: 'Response complete', failed: 'Failed', cancel_requested: 'Stopping — awaiting confirmation', cancelled: 'Stopped', incompatible: 'Connector incompatible' } as Record<string, string>)[phase] ?? 'Unknown provider state'; }
export function cloudCanSend(e: CloudExecution): boolean { return !e.turns.some(t => ['submission_uncertain', 'incompatible', 'reconnect_required'].includes(t.phase)); }
export function safeCloudUrl(value?: string): string | undefined { try { const u = new URL(value ?? ''); return u.protocol === 'https:' && !u.username && !u.password ? u.href : undefined; } catch { return undefined; } }
export function launchCloud(body: {title: string; prompt: string; project: string; tags: string[]; idempotency_key: string; cloud: CloudSelection}): Promise<Mission> { return createMission(body); }

export function cloudAccountLabel(a: CloudAccount): string { return a.label.replace(/^(Cursor Cloud|Grok Bot) · /, ""); }

export const CLOUD_PROVIDER_KEY = 'orb.cloud.provider';
const isProvider = (value: unknown): value is CloudProvider => typeof value === 'string' && value in cloudNames;
/** The provider the new-task composer opens on: the user's last explicit
 * choice when it still has an account, else Hermes when available, else the
 * first available provider, else the first provider with any account. */
export function defaultCloudProvider(accounts: CloudAccount[], persisted?: string | null): CloudProvider {
  const order = Object.keys(cloudNames) as CloudProvider[];
  if (isProvider(persisted) && accounts.some(a => a.provider === persisted)) return persisted;
  if (accounts.some(a => a.provider === 'hermes' && a.available)) return 'hermes';
  return order.find(p => accounts.some(a => a.provider === p && a.available))
    ?? order.find(p => accounts.some(a => a.provider === p))
    ?? 'hermes';
}
export function readCloudProvider(): string | null { try { return localStorage.getItem(CLOUD_PROVIDER_KEY); } catch { return null; } }
export function writeCloudProvider(value: CloudProvider) { try { localStorage.setItem(CLOUD_PROVIDER_KEY, value); } catch { /* kept in memory */ } }
/** Why "+" is unavailable for this account, or undefined when it accepts attachments. */
export function cloudAttachmentBlock(provider: CloudProvider, account?: CloudAccount): string | undefined {
  if (account?.capabilities.attachments) return undefined;
  return `${cloudNames[provider]} doesn’t accept attachments yet. Paste the content into the prompt, or switch to Hermes.`;
}
/** Prompt shown as the first bubble between submit and the first server state. */
export interface CloudLaunchSeed { prompt: string; images: import('./imageAttachments').DraftImage[]; provider: CloudProvider; account?: string }
export const cloudLaunchSeeds = new Map<string, CloudLaunchSeed>();
