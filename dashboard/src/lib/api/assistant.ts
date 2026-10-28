/**
 * Assistant Gateway API.
 *
 * These endpoints are assistant-named aliases over the Telegram compatibility
 * bridge while Hermes becomes the assistant runtime.
 */

import { apiGet, apiPost, apiPatch, apiDel } from "./core";
import type {
  TelegramActionExecution,
  TelegramChannel,
  TelegramChatMission,
  TelegramScheduledMessage,
  TelegramStructuredMemoryEntry,
  TelegramStructuredMemorySearchHit,
  CreateTelegramBotInput,
  UpdateTelegramChannelInput,
} from "./telegram";

export type AssistantGateway = TelegramChannel;
export type AssistantGatewayChat = TelegramChatMission;
export type AssistantGatewayScheduledMessage = TelegramScheduledMessage;
export type AssistantGatewayMemoryEntry = TelegramStructuredMemoryEntry;
export type AssistantGatewayMemorySearchHit = TelegramStructuredMemorySearchHit;
export type AssistantGatewayActionExecution = TelegramActionExecution;
export type CreateAssistantGatewayInput = CreateTelegramBotInput;
export type UpdateAssistantGatewayInput = UpdateTelegramChannelInput;

export interface AdoptHermesAssistantInput {
  gateway_id: string;
  allow_all_users?: boolean;
  model?: string;
  install_hermes_if_missing?: boolean;
}

export interface AdoptHermesAssistantResult {
  ok: boolean;
  gateway_id: string;
  gateway_username?: string | null;
  service_name: string;
  env_path: string;
  config_path: string;
  workspace_path: string;
  api_url: string;
  model: string;
  allowed_users_count: number;
  allow_all_users: boolean;
  legacy_gateway_active: boolean;
  hermes_installed: boolean;
  hermes_status: "ok" | "update_available" | "not_installed" | "error";
  notes: string[];
}

export interface HermesAssistantStatus {
  service_name: string;
  service_active: boolean;
  model: string | null;
  env_path: string;
  config_path: string;
  env_present: boolean;
  config_present: boolean;
  token_present: boolean;
  telegram_ok: boolean | null;
  telegram_bot_username: string | null;
  telegram_webhook_configured: boolean | null;
  telegram_pending_update_count: number | null;
  telegram_last_error: string | null;
  notes: string[];
}

const gatewayPath = "/api/control/assistant/gateways";

export async function listAssistantGateways(): Promise<AssistantGateway[]> {
  return apiGet<AssistantGateway[]>(gatewayPath, "Failed to fetch assistant gateways");
}

export async function createAssistantGateway(
  input: CreateAssistantGatewayInput
): Promise<AssistantGateway> {
  return apiPost<AssistantGateway>(gatewayPath, input, "Failed to create assistant gateway");
}

export async function updateAssistantGateway(
  gatewayId: string,
  updates: UpdateAssistantGatewayInput
): Promise<AssistantGateway> {
  return apiPatch<AssistantGateway>(
    `${gatewayPath}/${gatewayId}`,
    updates,
    "Failed to update assistant gateway"
  );
}

export async function deleteAssistantGateway(gatewayId: string): Promise<void> {
  await apiDel(`${gatewayPath}/${gatewayId}`, "Failed to delete assistant gateway");
}

export async function listAssistantGatewayChats(
  gatewayId: string
): Promise<AssistantGatewayChat[]> {
  return apiGet<AssistantGatewayChat[]>(
    `${gatewayPath}/${gatewayId}/chats`,
    "Failed to fetch assistant gateway chats"
  );
}

export async function listAssistantGatewayScheduledMessages(
  gatewayId: string,
  options?: { chat_id?: number; limit?: number }
): Promise<AssistantGatewayScheduledMessage[]> {
  const params = new URLSearchParams();
  if (options?.chat_id !== undefined) params.set("chat_id", String(options.chat_id));
  if (options?.limit !== undefined) params.set("limit", String(options.limit));
  const qs = params.toString();
  return apiGet<AssistantGatewayScheduledMessage[]>(
    `${gatewayPath}/${gatewayId}/scheduled${qs ? `?${qs}` : ""}`,
    "Failed to fetch assistant gateway scheduled messages"
  );
}

export async function listAssistantGatewayActions(
  gatewayId: string,
  options?: { chat_id?: number; limit?: number }
): Promise<AssistantGatewayActionExecution[]> {
  const params = new URLSearchParams();
  if (options?.chat_id !== undefined) params.set("chat_id", String(options.chat_id));
  if (options?.limit !== undefined) params.set("limit", String(options.limit));
  const qs = params.toString();
  return apiGet<AssistantGatewayActionExecution[]>(
    `${gatewayPath}/${gatewayId}/actions${qs ? `?${qs}` : ""}`,
    "Failed to fetch assistant gateway actions"
  );
}

export async function listAssistantGatewayMemory(
  gatewayId: string,
  options?: { chat_id?: number; limit?: number; q?: string; subject_user_id?: number }
): Promise<AssistantGatewayMemoryEntry[]> {
  const params = new URLSearchParams();
  if (options?.chat_id !== undefined) params.set("chat_id", String(options.chat_id));
  if (options?.limit !== undefined) params.set("limit", String(options.limit));
  if (options?.q) params.set("q", options.q);
  if (options?.subject_user_id !== undefined) {
    params.set("subject_user_id", String(options.subject_user_id));
  }
  const qs = params.toString();
  return apiGet<AssistantGatewayMemoryEntry[]>(
    `${gatewayPath}/${gatewayId}/memory${qs ? `?${qs}` : ""}`,
    "Failed to fetch assistant gateway memory"
  );
}

export async function searchAssistantGatewayMemory(
  gatewayId: string,
  options: { q: string; chat_id?: number; limit?: number; subject_user_id?: number }
): Promise<AssistantGatewayMemorySearchHit[]> {
  const params = new URLSearchParams();
  params.set("q", options.q);
  if (options.chat_id !== undefined) params.set("chat_id", String(options.chat_id));
  if (options.limit !== undefined) params.set("limit", String(options.limit));
  if (options.subject_user_id !== undefined) {
    params.set("subject_user_id", String(options.subject_user_id));
  }
  return apiGet<AssistantGatewayMemorySearchHit[]>(
    `${gatewayPath}/${gatewayId}/memory-search?${params.toString()}`,
    "Failed to search assistant gateway memory"
  );
}

export async function sendAssistantGatewayTestMessage(
  gatewayId: string,
  chatId: number,
  text = "✅ Test message from the Core dashboard."
): Promise<void> {
  await apiPost(
    "/api/control/telegram/send",
    { channel_id: gatewayId, chat_id: chatId, text },
    "Failed to send test message"
  );
}

export async function adoptHermesAssistant(
  input: AdoptHermesAssistantInput
): Promise<AdoptHermesAssistantResult> {
  return apiPost<AdoptHermesAssistantResult>(
    "/api/system/hermes-assistant/adopt",
    input,
    "Failed to adopt gateway into Hermes"
  );
}

export async function getHermesAssistantStatus(): Promise<HermesAssistantStatus> {
  return apiGet<HermesAssistantStatus>(
    "/api/system/hermes-assistant/status",
    "Failed to fetch Hermes assistant status"
  );
}

export interface HermesSkill {
  name: string;
  description: string | null;
  category: string | null;
  version: string | null;
  path: string;
}

export interface HermesSkillsResponse {
  root: string;
  available: boolean;
  skills: HermesSkill[];
}

/** Skills the Hermes runtime installed for itself (agentskills.io / skills.sh). */
export async function listHermesAssistantSkills(): Promise<HermesSkillsResponse> {
  return apiGet<HermesSkillsResponse>(
    "/api/system/hermes-assistant/skills",
    "Failed to fetch Hermes assistant skills"
  );
}

export interface HermesRemoteStatus {
  installed: boolean;
  enabled: boolean;
  /** The API server answers on its loopback port (restart applies pending env). */
  active: boolean;
  /** Bearer token for remote connections; auto-provisioned on first read. */
  key: string | null;
  path: string;
}

/** Remote-access status for the Hermes API server (desktop proxy mode). */
export async function getHermesRemoteStatus(): Promise<HermesRemoteStatus> {
  return apiGet<HermesRemoteStatus>(
    "/api/system/hermes-assistant/remote",
    "Failed to fetch Hermes remote status"
  );
}

export interface RotateHermesRemoteKeyResult {
  key: string;
  path: string;
  service_restarted: boolean;
}

export interface ApplyHermesRemoteResult {
  service_restarted: boolean;
  active: boolean;
}

/** Restart the Hermes gateway so a freshly provisioned key takes effect. */
export async function applyHermesRemote(): Promise<ApplyHermesRemoteResult> {
  return apiPost<ApplyHermesRemoteResult>(
    "/api/system/hermes-assistant/remote/apply",
    {},
    "Failed to apply Hermes remote settings"
  );
}

/** Enable the Hermes API server and rotate its bearer token. */
export async function rotateHermesRemoteKey(): Promise<RotateHermesRemoteKeyResult> {
  return apiPost<RotateHermesRemoteKeyResult>(
    "/api/system/hermes-assistant/remote/key",
    {},
    "Failed to generate Hermes remote token"
  );
}
