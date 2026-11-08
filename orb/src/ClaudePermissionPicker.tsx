import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import type { Mission } from "./api";
import * as Ic from "./icons";
import {
  inspectMissionWorktree,
  localBinding,
  setMissionPermissionMode,
  type ClaudePermissionMode,
  type WorktreeLaunchMode,
  type WorktreeStatus,
} from "./localAgents";
import { Picker } from "./Picker";

export const [draftClaudePermission, setDraftClaudePermission] =
  createSignal<ClaudePermissionMode>("supervised");
export const [draftWorktreeMode, setDraftWorktreeMode] =
  createSignal<WorktreeLaunchMode>("auto");

export const claudePermissionLabel = (mode?: string | null): string => {
  switch (mode) {
    case "acceptEdits":
      return "Auto-edit";
    case "auto":
      return "Auto";
    case "bypassPermissions":
      return "Full access";
    default:
      return "Supervised";
  }
};

export function normalizeClaudePermission(mode?: string | null): ClaudePermissionMode {
  if (mode === "acceptEdits" || mode === "auto" || mode === "bypassPermissions") return mode;
  return "supervised";
}

const PERMISSION_ITEMS: Array<{ id: ClaudePermissionMode; label: string; description: string }> = [
  { id: "supervised", label: "Supervised", description: "Prompt before commands and file edits" },
  { id: "acceptEdits", label: "Auto-edit", description: "Allow workspace edits; prompt before commands" },
  { id: "auto", label: "Auto", description: "Allow safe commands and workspace edits" },
  { id: "bypassPermissions", label: "Full access", description: "Run tools without confirmation" },
];

export function ClaudePermissionPicker(p: {
  value: ClaudePermissionMode;
  disabled?: boolean;
  missionId?: string;
  onChange: (mode: ClaudePermissionMode) => void;
}) {
  const [open, setOpen] = createSignal(false);
  return (
    <div class="under-model-wrap model-wrap">
      <button
        type="button"
        class={`model under-model ${open() ? "on" : ""}`}
        disabled={p.disabled}
        aria-label={`Permissions: ${claudePermissionLabel(p.value)}`}
        aria-haspopup="listbox"
        aria-expanded={open()}
        title={
          p.missionId
            ? "Claude permissions · applies live to the running session"
            : "Claude permissions for this agent"
        }
        onClick={() => setOpen(!open())}
      >
        {claudePermissionLabel(p.value)} <Ic.ChevronDown size={12} />
      </button>
      <Show when={open()}>
        <Picker
          label="Claude permissions"
          searchable={false}
          placement="top-start"
          selected={p.value}
          items={PERMISSION_ITEMS}
          onClose={() => setOpen(false)}
          onSelect={(value) => {
            setOpen(false);
            p.onChange(value as ClaudePermissionMode);
          }}
        />
      </Show>
    </div>
  );
}

export function MissionClaudePermission(p: {
  mission: Mission;
  onMission?: (mission: Mission, authoritative?: boolean) => void;
  onError?: (message: string) => void;
}) {
  const [saving, setSaving] = createSignal(false);
  const current = () =>
    normalizeClaudePermission(
      localBinding(p.mission.id)?.permissionMode ?? p.mission.permission_mode,
    );
  const update = async (next: ClaudePermissionMode) => {
    if (saving() || next === current()) return;
    setSaving(true);
    try {
      await setMissionPermissionMode(p.mission.id, next);
      p.onMission?.({ ...p.mission, permission_mode: next }, true);
    } catch (e) {
      p.onError?.(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  };
  return (
    <>
      <span class="under-sep" aria-hidden="true">·</span>
      <ClaudePermissionPicker
        value={current()}
        disabled={saving()}
        missionId={p.mission.id}
        onChange={(next) => void update(next)}
      />
    </>
  );
}

export function WorktreeLaunchPicker(p: {
  cwd?: string | null;
  value: WorktreeLaunchMode;
  disabled?: boolean;
  onChange: (mode: WorktreeLaunchMode) => void;
}) {
  const [open, setOpen] = createSignal(false);
  const [status, setStatus] = createSignal<WorktreeStatus | null>(null);
  createEffect(() => {
    const dir = p.cwd?.trim() ?? "";
    let active = true;
    onCleanup(() => {
      active = false;
    });
    if (!dir) {
      setStatus(null);
      return;
    }
    void inspectMissionWorktree(dir, undefined, true)
      .then((res) => {
        if (active) setStatus(res?.is_git_repo ? res : null);
      })
      .catch(() => {
        if (active) setStatus(null);
      });
  });

  const effectiveLabel = () => {
    if (p.value === "worktree") return "Worktree";
    if (p.value === "local") return "Local";
    return status()?.decision_word === 513 ? "Worktree · auto" : "Local";
  };

  return (
    <Show when={status()?.is_git_repo}>
      <span class="picks-sep">·</span>
      <div class="under-model-wrap model-wrap">
        <button
          type="button"
          class={`model under-model ${open() ? "on" : ""}`}
          disabled={p.disabled}
          aria-label={`Checkout isolation: ${effectiveLabel()}`}
          aria-haspopup="listbox"
          aria-expanded={open()}
          title={
            status()?.decision_word === 513
              ? "Repository has active changes or runs — isolated git worktree recommended"
              : "Choose whether this mission runs in the current checkout or an isolated git worktree"
          }
          onClick={() => setOpen(!open())}
        >
          {effectiveLabel()} <Ic.ChevronDown size={12} />
        </button>
        <Show when={open()}>
          <Picker
            label="Git checkout"
            searchable={false}
            placement="top-start"
            selected={p.value}
            items={[
              {
                id: "auto",
                label: "Automatic",
                description:
                  status()?.decision_word === 513
                    ? "Creates an isolated sibling worktree because this repo is busy"
                    : "Uses the local checkout unless another agent is active here",
              },
              {
                id: "worktree",
                label: "Worktree",
                description: "Always create an isolated git worktree for this mission",
              },
              {
                id: "local",
                label: "Local",
                description: "Run directly in the selected directory without a worktree",
              },
            ]}
            onClose={() => setOpen(false)}
            onSelect={(val) => {
              setOpen(false);
              p.onChange(val as WorktreeLaunchMode);
            }}
          />
        </Show>
      </div>
    </Show>
  );
}
