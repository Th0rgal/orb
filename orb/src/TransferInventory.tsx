import { For, Show, createMemo } from "solid-js";
import type { Manifest } from "./machineTransfer";

export const formatBytes = (n: number) => n >= 1024 ** 3 ? `${(n / 1024 ** 3).toFixed(1)} GiB` : n >= 1024 ** 2 ? `${(n / 1024 ** 2).toFixed(1)} MiB` : n >= 1024 ? `${Math.round(n / 1024)} KiB` : `${n} B`;
export const formatCount = (n: number, noun: string) => `${n.toLocaleString("en-US")} ${noun}${n === 1 ? "" : "s"}`;
const BUNDLE = ".transfer-git.bundle";
/** Paths listed under an opened folder; a workspace may hold 50,000 of them. */
const SHOWN = 50;
/** Folders listed, largest first; a workspace may hold as many folders as files. */
const GROUPS = 100;
export interface InventoryGroup { name: string; files: number; bytes: number; history: number; paths: string[] }
export const LOOSE = "Top-level files";
/** The moved files by top-level folder, largest first. Files at the root share one group; Git bundles count as history, not as files. */
export function inventoryGroups(manifest: Manifest): InventoryGroup[] {
  const groups = new Map<string, InventoryGroup>();
  for (const file of manifest.files) {
    const slash = file.path.indexOf("/"), bundle = file.path === BUNDLE || file.path.endsWith(`/${BUNDLE}`);
    const name = slash < 0 ? bundle ? "Workspace" : LOOSE : file.path.slice(0, slash);
    const group = groups.get(name) ?? { name, files: 0, bytes: 0, history: 0, paths: [] };
    group.bytes += file.bytes;
    if (bundle) group.history += file.bytes;
    else { group.files++; if (group.paths.length < SHOWN) group.paths.push(slash < 0 ? file.path : file.path.slice(slash + 1)); }
    groups.set(name, group);
  }
  return [...groups.values()].sort((a, b) => b.bytes - a.bytes || a.name.localeCompare(b.name));
}

export function TransferInventory(p: { manifest: Manifest }) {
  const groups = createMemo(() => inventoryGroups(p.manifest));
  const largest = () => Math.max(1, ...groups().map(g => g.bytes));
  const files = () => groups().reduce((n, g) => n + g.files, 0);
  const links = () => p.manifest.links ?? [];
  const skipped = () => p.manifest.skipped ?? [];
  return <section class="transfer-inventory" aria-label="Workspace inventory">
    <dl class="transfer-stats">
      <div><dt>Size</dt><dd>{formatBytes(p.manifest.bytes)}</dd></div>
      <div><dt>Files</dt><dd>{files().toLocaleString("en-US")}</dd></div>
      <div><dt>Links</dt><dd>{links().length.toLocaleString("en-US")}</dd></div>
    </dl>
    <Show when={groups().length}>
      <h3>Moving</h3>
      <div class="transfer-groups">
        <For each={groups().slice(0, GROUPS)}>{g => <details class="transfer-group" classList={{ leaf: !g.paths.length }}>
          <summary><span classList={{ "transfer-path": g.name !== LOOSE && g.name !== "Workspace" }}>{g.name}</span><span class="transfer-meta">{g.files ? formatCount(g.files, "file") : "Git history"} · {formatBytes(g.bytes)}</span><span class="transfer-bar" style={{ width: `${Math.max(2, g.bytes / largest() * 100)}%` }} /></summary>
          <Show when={g.paths.length}><ul>
            <For each={g.paths}>{path => <li class="transfer-path">{path}</li>}</For>
            <Show when={g.files > g.paths.length}><li class="transfer-more">and {formatCount(g.files - g.paths.length, "more file")}</li></Show>
            <Show when={g.history}><li class="transfer-more">Git history · {formatBytes(g.history)}</li></Show>
          </ul></Show>
        </details>}</For>
        <Show when={groups().length > GROUPS}><p class="transfer-more">and {formatCount(groups().length - GROUPS, "smaller folder")}</p></Show>
      </div>
    </Show>
    <Show when={skipped().length}><details class="transfer-section" open>
      <summary>Left behind<span class="transfer-count warn">{skipped().length}</span></summary>
      <p>These stay on the source: they cannot be recreated on another machine.</p>
      <ul><For each={skipped().slice(0, SHOWN)}>{s => <li><span class="transfer-path">{s.path}</span><small>{s.reason}</small></li>}</For>
        <Show when={skipped().length > SHOWN}><li class="transfer-more">and {formatCount(skipped().length - SHOWN, "more path")}</li></Show></ul>
    </details></Show>
    <Show when={links().length}><details class="transfer-section">
      <summary>Links<span class="transfer-count">{links().length}</span></summary>
      <ul><For each={links().slice(0, SHOWN)}>{l => <li><span class="transfer-path">{l.path}</span><small>→ {l.target}</small></li>}</For>
        <Show when={links().length > SHOWN}><li class="transfer-more">and {formatCount(links().length - SHOWN, "more link")}</li></Show></ul>
    </details></Show>
    <Show when={p.manifest.excluded.length}><details class="transfer-section">
      <summary>Excluded<span class="transfer-count">{p.manifest.excluded.length}</span></summary>
      <p>Credentials, generated configuration and caches are never moved.</p>
      <ul><For each={p.manifest.excluded.slice(0, SHOWN)}>{path => <li><span class="transfer-path">{path}</span></li>}</For>
        <Show when={p.manifest.excluded.length > SHOWN}><li class="transfer-more">and {formatCount(p.manifest.excluded.length - SHOWN, "more path")}</li></Show></ul>
    </details></Show>
  </section>;
}
