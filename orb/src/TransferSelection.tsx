import { For, Show, createMemo } from "solid-js";
import type { InventoryRow, WorkspaceInventory } from "./machineTransfer";
import { formatBytes, formatCount } from "./TransferInventory";

/** Paths whose default was changed: a moved one unticked, a left-behind one ticked. */
export type Choice = Record<string, boolean>;
const moves = (row: InventoryRow) => row.state === "moved";
export const ticked = (row: InventoryRow, choice: Choice) => choice[row.path] ?? moves(row);
const beneath = (path: string, parent: string) => path.startsWith(`${parent}/`);
/** A row under an unticked folder follows it and cannot be chosen on its own. */
export const blocked = (row: InventoryRow, rows: InventoryRow[], choice: Choice) => rows.some(r => moves(r) && r.folder && beneath(row.path, r.path) && !ticked(r, choice));
const top = (row: InventoryRow) => !row.path.includes("/");

/** What the snapshot would carry: the default totals, less what was unticked, plus what was ticked. */
export function selectionTotals(inventory: Pick<WorkspaceInventory, "rows" | "bytes" | "files" | "reserved">, choice: Choice) {
  let bytes = inventory.bytes + (inventory.reserved?.bytes ?? 0), files = inventory.files + (inventory.reserved?.files ?? 0);
  for (const row of inventory.rows) {
    if (blocked(row, inventory.rows, choice) || ticked(row, choice) === moves(row)) continue;
    const sign = moves(row) ? -1 : 1;
    bytes += sign * row.bytes; files += sign * row.files;
  }
  return { bytes, files };
}
export function selectionRequest(rows: InventoryRow[], choice: Choice) {
  const free = rows.filter(row => !blocked(row, rows, choice));
  return { omit: free.filter(row => moves(row) && !ticked(row, choice)).map(row => row.path), include: free.filter(row => !moves(row) && ticked(row, choice)).map(row => row.path) };
}
const REASON: Record<string, string> = { ignored: "ignored by Git", rebuildable: "build or toolchain" };

export function TransferSelection(p: { inventory: WorkspaceInventory; choice: Choice; disabled?: boolean; onChoice: (choice: Choice) => void }) {
  const rows = () => p.inventory.rows;
  const totals = createMemo(() => selectionTotals(p.inventory, p.choice));
  // A left-behind path appears under its top-level folder, or on its own when nothing else there moves.
  const roots = createMemo(() => rows().filter(row => top(row) || !rows().some(r => top(r) && moves(r) && beneath(row.path, r.path))));
  const children = (parent: InventoryRow) => moves(parent) && parent.folder ? rows().filter(row => beneath(row.path, parent.path)) : [];
  const over = () => totals().bytes > p.inventory.limits.bytes || totals().files > p.inventory.limits.files;
  const set = (row: InventoryRow, on: boolean) => { const next = { ...p.choice }; if (on === moves(row)) delete next[row.path]; else next[row.path] = on; p.onChoice(next); };
  const Line = (l: { row: InventoryRow; name: string }) => <label class="transfer-choice" classList={{ off: !ticked(l.row, p.choice) || blocked(l.row, rows(), p.choice) }}>
    <input type="checkbox" checked={ticked(l.row, p.choice) && !blocked(l.row, rows(), p.choice)} disabled={p.disabled || blocked(l.row, rows(), p.choice)} onChange={e => set(l.row, e.currentTarget.checked)} aria-label={`Move ${l.row.path}`} />
    <span class="transfer-path" title={l.row.path}>{l.name}{l.row.folder ? "/" : ""}</span>
    <Show when={REASON[l.row.state]}><span class="transfer-tag">{REASON[l.row.state]}</span></Show>
    <span class="transfer-meta">{l.row.folder ? `${formatCount(l.row.files, "file")} · ` : ""}{formatBytes(l.row.bytes)}</span>
  </label>;
  const Meter = (m: { label: string; value: number; limit: number; text: string }) => <div class="transfer-meter" classList={{ over: m.value > m.limit }}>
    <span>{m.label}</span><span>{m.text}</span>
    <div role="meter" aria-label={m.label} aria-valuemin={0} aria-valuemax={m.limit} aria-valuenow={Math.min(m.value, m.limit)}><i style={{ width: `${Math.min(100, m.value / m.limit * 100)}%` }} /></div>
  </div>;
  return <section class="transfer-inventory transfer-selection" aria-label="Choose what to move">
    <div class="transfer-meters">
      <Meter label="Size" value={totals().bytes} limit={p.inventory.limits.bytes} text={`${formatBytes(totals().bytes)} of ${formatBytes(p.inventory.limits.bytes)}`} />
      <Meter label="Files" value={totals().files} limit={p.inventory.limits.files} text={`${totals().files.toLocaleString("en-US")} of ${p.inventory.limits.files.toLocaleString("en-US")}`} />
    </div>
    <Show when={over()}><p class="transfer-over" role="status">Too large to move. Untick folders until both bars fit.</p></Show>
    <h3>Choose what to move</h3>
    <div class="transfer-groups">
      <For each={roots()}>{row => <Show when={children(row).length} fallback={<div class="transfer-leaf"><Line row={row} name={row.path} /></div>}>
        <details class="transfer-group"><summary><Line row={row} name={row.path} /></summary>
          <ul><For each={children(row)}>{child => <li><Line row={child} name={child.path.slice(row.path.length + 1)} /></li>}</For></ul>
        </details>
      </Show>}</For>
    </div>
    <p class="transfer-note">Sizes include each repository's Git history.<Show when={p.inventory.reserved?.bytes}> {formatBytes(p.inventory.reserved!.bytes)} always move{p.inventory.reserved!.files === 1 ? "s" : ""}: the workspace's own history and a long conversation.</Show> Unticked folders stay on the source. Build output and toolchains can be rebuilt on the destination.
      <Show when={p.inventory.protected}> {formatCount(p.inventory.protected, "credential or configuration path")} never move{p.inventory.protected === 1 ? "s" : ""}.</Show>
      <Show when={p.inventory.truncated}> Only the largest folders are listed.</Show></p>
  </section>;
}
