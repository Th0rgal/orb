import { api, ApiError, createMission, type Mission } from './api';
export type CloudProvider = 'chatgpt' | 'grok_bot' | 'cursor_cloud' | 'hermes';
export const cloudNames: Record<CloudProvider, string> = { chatgpt: 'ChatGPT', grok_bot: 'Grok Bot', cursor_cloud: 'Cursor Cloud', hermes: 'Hermes' };
export interface ModelParam {id:string;value:string}
export interface CloudSelection { model_params?: ModelParam[]; provider: CloudProvider; account: string; repository?: string; git_ref?: string; model?: string }
export interface CloudAccount { id: string; provider: CloudProvider; label: string; available: boolean; experimental: boolean; reason?: string; capabilities: { models: boolean; repository: boolean; attachments: boolean; follow_up: boolean; cancel: boolean; artifacts: boolean; detailed_events: boolean } }
export interface CloudTurn { model?:string; model_params?: ModelParam[]; key: string; prompt: string; phase: string; external_id?: string; result?: string; detail?: string; artifacts: { kind?: string; run_id?:string; request?:{request_id?:string;command?:string;choices?:string[]}; path: string; sizeBytes?: number }[]; branches: { branch?: string; prUrl?: string }[]; usage?: unknown }
export interface CloudExecution { mission_id: string; revision: number; selection: CloudSelection; external_url?: string; turns: CloudTurn[] }
export async function cloudAccounts(): Promise<CloudAccount[]> { try { return await api<CloudAccount[]>('/api/cloud/accounts'); } catch (error) { if (error instanceof ApiError && error.status === 404) throw new Error('Cloud agents are not available on this Core yet. Core needs the cloud agent update.'); throw error; } }
export const cloudExecution = (id: string) => api<CloudExecution>(`/api/control/missions/${encodeURIComponent(id)}/cloud`);
export function cloudPhase(phase: string): string { return ({ queued: 'Queued', submitting: 'Starting', submission_uncertain: 'Submission needs verification', running: 'Working', waiting_user: 'Waiting for your reply', reconnect_required: 'Reconnect account', response_complete: 'Response complete', failed: 'Failed', cancel_requested: 'Stopping — awaiting confirmation', cancelled: 'Stopped', incompatible: 'Connector incompatible' } as Record<string, string>)[phase] ?? 'Unknown provider state'; }
export function cloudCanSend(e: CloudExecution): boolean { return !e.turns.some(t => ['submission_uncertain', 'incompatible', 'reconnect_required'].includes(t.phase)); }
export function safeCloudUrl(value?: string): string | undefined { try { const u = new URL(value ?? ''); return u.protocol === 'https:' && !u.username && !u.password ? u.href : undefined; } catch { return undefined; } }
export function launchCloud(body: {title: string; prompt: string; project: string; tags: string[]; idempotency_key: string; cloud: CloudSelection}): Promise<Mission> { return createMission(body); }

export function cloudAccountLabel(a: CloudAccount): string { const match = /^chatgpt-profile(?:-(\d+))?$/.exec(a.id); return match ? `Profile ${match[1] ?? 1}` : a.label.replace(/^(ChatGPT|Cursor Cloud|Grok Bot) · /, ""); }
