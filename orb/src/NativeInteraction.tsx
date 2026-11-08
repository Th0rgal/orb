import { followInteraction } from "./nativeInteractionStream";
import { ErrorToast } from "./toast";
import { Show, createEffect, createRoot, createSignal, onCleanup, untrack, type Component } from "solid-js";
import * as apiModule from "./api";
import { observeMissionInteraction } from "./missionAttention";
import { sideQuestionKey } from "./sideQuestionStorage";
import type { StreamItem } from "./transcriptModel";
import type PromptType from "./NativeInteractionPrompt";

let cachedPrompt: typeof PromptType | undefined;
let loadingPrompt: Promise<typeof PromptType> | undefined;
function ensurePrompt(onLoaded: (comp: typeof PromptType) => void) {
  if (cachedPrompt) return;
  loadingPrompt ??= import("./NativeInteractionPrompt").then(m => (cachedPrompt = m.default));
  void loadingPrompt.then(onLoaded);
}

function connectionVersionSafe(): number {
  return typeof apiModule.connectionVersion === "function" ? apiModule.connectionVersion() : 0;
}

export type NativeInteractionRequest = {
  id: string;
  method: string;
  params: {
    plan?: string;
    tool?: string;
    input?: { command?: string; file_path?: string; description?: string };
    questions?: Array<{
      id?: string;
      question: string;
      header?: string;
      multiSelect?: boolean;
      options?: Array<{ label: string; description?: string }>;
    }>;
  };
};

export type CompletedPlanTurn = { id: string; plan: string; boundary?: string };

const ANSWERED_STORAGE_PREFIX = "orb.native.answered:";

function purgeAnsweredStorage(storage: Storage | undefined) {
  if (!storage) return;
  try {
    const keys: string[] = [];
    for (let i = 0; i < storage.length; i++) {
      const k = storage.key(i);
      if (k?.startsWith(ANSWERED_STORAGE_PREFIX)) keys.push(k);
    }
    for (const k of keys) storage.removeItem(k);
  } catch { /* ignore */ }
}

let observedAuthenticated = Boolean(typeof apiModule.getJwt === "function" ? apiModule.getJwt() : null);
function syncAnsweredAuthTransition() {
  const isAuthenticated = Boolean(typeof apiModule.getJwt === "function" ? apiModule.getJwt() : null);
  if (observedAuthenticated && !isAuthenticated) {
    purgeAnsweredStorage(typeof localStorage !== "undefined" ? localStorage : undefined);
    purgeAnsweredStorage(typeof sessionStorage !== "undefined" ? sessionStorage : undefined);
  }
  observedAuthenticated = isAuthenticated;
}

createRoot(() => {
  createEffect(() => {
    connectionVersionSafe();
    syncAnsweredAuthTransition();
  });
});

function answeredKey(mission: string): string {
  connectionVersionSafe();
  syncAnsweredAuthTransition();
  return `orb.native.answered:v2:${sideQuestionKey(mission)}`;
}

const readStorageList = (storage: Storage | undefined, key: string): string[] => {
  if (!storage) return [];
  try {
    const raw = JSON.parse(storage.getItem(key) ?? "[]");
    return Array.isArray(raw) ? raw.filter((id): id is string => typeof id === "string" && id.length > 0) : [];
  } catch {
    return [];
  }
};

const readAnsweredByKey = (key: string): Set<string> =>
  new Set([
    ...readStorageList(typeof localStorage !== "undefined" ? localStorage : undefined, key),
    ...readStorageList(typeof sessionStorage !== "undefined" ? sessionStorage : undefined, key),
  ]);

export function NativeInteraction(p: {
  mission: string;
  active: boolean;
  remote?: boolean;
  items?: StreamItem[];
  onSend?: (text: string) => Promise<unknown> | unknown;
}) {
  const [request, setRequest] = createSignal<NativeInteractionRequest | null>(null, {
    equals: (previous, next) => previous === next || JSON.stringify(previous) === JSON.stringify(next),
  });
  const [answers, setAnswers] = createSignal<Record<string, string[]>>({});
  const [feedback, setFeedback] = createSignal("");
  const [error, setError] = createSignal("");
  const [subscriptionError, setSubscriptionError] = createSignal("");
  const [retry, setRetry] = createSignal(0);
  const [answeredTick, setAnsweredTick] = createSignal(0);
  const [PromptComp, setPromptComp] = createSignal<Component<Parameters<typeof PromptType>[0]> | undefined>(cachedPrompt);
  const answered = readAnsweredByKey(answeredKey(p.mission));

  const rememberAnswered = (id: string, mission: string, version: number, targetKey: string) => {
    if (!id || version !== connectionVersionSafe()) return;
    const bounded = [...readAnsweredByKey(targetKey).add(id)].slice(-256);
    if (mission === p.mission && targetKey === answeredKey(p.mission)) {
      answered.clear();
      for (const entry of bounded) answered.add(entry);
      setAnsweredTick(n => n + 1);
    }
    const payload = JSON.stringify(bounded);
    try { localStorage.setItem(targetKey, payload); } catch { /* ignore */ }
    try { sessionStorage.setItem(targetKey, payload); } catch { /* ignore */ }
  };

  let currentMission = p.mission;
  let currentScopeKey = answeredKey(p.mission);
  let currentConnection = connectionVersionSafe();

  createEffect(() => {
    connectionVersionSafe();
    const current = request();
    if (p.active && current) onCleanup(observeMissionInteraction(p.mission, current));
  });

  createEffect(() => {
    const id = p.mission;
    retry();
    setSubscriptionError("");
    const version = connectionVersionSafe();
    const scopeKey = answeredKey(id);
    if (version !== currentConnection || scopeKey !== currentScopeKey || id !== currentMission) {
      answered.clear();
      for (const k of readAnsweredByKey(scopeKey)) answered.add(k);
      setRequest(null);
      currentConnection = version;
      currentScopeKey = scopeKey;
      currentMission = id;
    }
    if (p.remote) {
      if (!p.active) {
        setRequest(null);
        return;
      }
      const item = p.items?.find(
        i =>
          i.kind === "tool" &&
          !i.done &&
          !answered.has(i.callId) &&
          ["ui_native_request", "AskUserQuestion", "question"].includes(i.name),
      );
      if (item?.kind === "tool") {
        const args = item.args as {
          method?: string;
          params?: NativeInteractionRequest["params"];
          questions?: NativeInteractionRequest["params"]["questions"];
        };
        const next: NativeInteractionRequest = {
          id: item.callId,
          method: args.method ?? "claude_questions",
          params: args.params ?? args,
        };
        if (next.id !== untrack(request)?.id) {
          setAnswers({});
          setFeedback("");
          setError("");
        }
        setRequest(next);
      } else setRequest(null);
      return;
    }
    if (!p.active) {
      setRequest(null);
      return;
    }
    onCleanup(
      followInteraction<NativeInteractionRequest>(
        id,
        next => {
          if (next?.id !== untrack(request)?.id) {
            setAnswers({});
            setFeedback("");
            setError("");
          }
          setRequest(next && !answered.has(next.id) ? next : null);
        },
        failure => setSubscriptionError(`Couldn’t receive interaction updates: ${String(failure)}`),
      ),
    );
  });

  const completedPlanTurn = (): CompletedPlanTurn | null => {
    answeredTick();
    if (p.active || request() || !p.onSend || !p.items?.length) return null;
    let lastUserIdx = -1;
    for (let i = p.items.length - 1; i >= 0; i--) {
      const item = p.items[i];
      if (item.kind === "user" && !item.queued) {
        lastUserIdx = i;
        break;
      }
    }
    if (lastUserIdx < 0) return null;
    const userItem = p.items[lastUserIdx];
    if (userItem.kind !== "user" || !/^\s*\/plan(?:\s|$)/.test(userItem.text) || answered.has(userItem.key)) return null;
    const after = p.items.slice(lastUserIdx + 1);
    if (after.some(i => i.kind === "error")) return null;
    const replyText = [...after]
      .reverse()
      .find((i): i is Extract<StreamItem, { kind: "text" }> => i.kind === "text" && !i.live && !!i.text.trim());
    if (!replyText) return null;
    return { id: userItem.key, plan: replyText.text, boundary: p.items.at(-1)?.key };
  };

  const hasPrompt = () => Boolean(request() || completedPlanTurn());
  createEffect(() => {
    if (hasPrompt() && !PromptComp()) ensurePrompt(c => setPromptComp(() => c));
  });

  return (
    <>
      <ErrorToast
        error={subscriptionError()}
        title="Couldn’t subscribe to interaction requests"
        background
        action={{ label: "Retry", run: () => setRetry(n => n + 1) }}
      />
      <Show when={hasPrompt() && PromptComp()}>
        {Comp => {
          const C = Comp();
          return (
            <C
              mission={p.mission}
              remote={p.remote}
              items={p.items}
              onSend={p.onSend}
              request={request}
              setRequest={setRequest}
              completedPlanTurn={completedPlanTurn}
              answers={answers}
              setAnswers={setAnswers}
              feedback={feedback}
              setFeedback={setFeedback}
              error={error}
              setError={setError}
              connectionVersion={connectionVersionSafe}
              answeredKey={answeredKey}
              rememberAnswered={rememberAnswered}
            />
          );
        }}
      </Show>
    </>
  );
}
