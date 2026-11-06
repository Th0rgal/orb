import { For, Show } from "solid-js";
import { Menu } from "./Menu";
import { ChevronRight, CloudIcon } from "./icons";
import {
  formatAutoManagedTarget,
  parseAutoManagedTarget,
} from "./machines/nodes";
import {
  compactSizeSpec,
  is24hCommitmentSize,
  machineProviderKey,
  providerAllowedSizes,
  providerLabel,
  sizeLabel,
  usdPerHour,
  type ManagedCatalogState,
  type ManagedProviderInfo,
  type ManagedSize,
} from "./managedMachineModel";

export interface ActiveProviderSubmenu {
  provider: string;
  anchor: HTMLButtonElement;
}

export function CloudVmProviderRows(p: {
  providers: readonly ManagedProviderInfo[];
  catalog?: ManagedCatalogState;
  selectedTarget?: string | null;
  subtitle?: string;
  activeSubmenu: ActiveProviderSubmenu | undefined;
  onSubmenuChange: (next: ActiveProviderSubmenu | undefined) => void;
  onSelectSize: (provider: ManagedProviderInfo, size: ManagedSize) => void;
}) {
  const parsed = () => parseAutoManagedTarget(p.selectedTarget);
  const openProvider = () => {
    const sub = p.activeSubmenu;
    if (!sub) return undefined;
    return p.providers.find(x => machineProviderKey(x.provider) === machineProviderKey(sub.provider));
  };

  return (
    <Show when={p.providers.length > 0}>
      <div class="menu-sep" />
      <div class="machine-section-label machine-cloud-vms-label">Cloud VMs</div>
      <For each={p.providers}>
        {(prov) => {
          const key = () => machineProviderKey(prov.provider);
          const chosenSize = () => (parsed()?.provider === key() ? parsed()?.size : undefined);
          const saturated = () => prov.availability?.status === "saturated";
          const isOpen = () => machineProviderKey(p.activeSubmenu?.provider) === key();
          const openSub = (anchor: HTMLButtonElement) => p.onSubmenuChange({ provider: prov.provider, anchor });
          return (
            <button
              type="button"
              role="menuitem"
              data-provider={prov.provider}
              class={`menu-item machine-provider-trigger ${chosenSize() ? "on" : ""}`}
              aria-haspopup="menu"
              aria-expanded={isOpen()}
              onMouseEnter={(e) => openSub(e.currentTarget)}
              onClick={(e) => openSub(e.currentTarget)}
              onKeyDown={(e) => {
                if (e.key === "ArrowRight") {
                  e.preventDefault();
                  e.stopPropagation();
                  openSub(e.currentTarget);
                }
              }}
            >
              <span class="menu-ico">
                <CloudIcon size={14} />
              </span>
              <span class="menu-col">
                <span class="menu-title">{providerLabel(prov.provider)}</span>
                <Show when={chosenSize()}>
                  <span class="machine-inline-note">{sizeLabel(chosenSize()!)}</span>
                </Show>
                <Show when={!chosenSize() && saturated()}>
                  <span class="machine-inline-note">at capacity</span>
                </Show>
              </span>
              <span class="menu-chevron" aria-hidden="true">›</span>
            </button>
          );
        }}
      </For>
      <Show when={p.activeSubmenu && openProvider()}>
        {(prov) => (
          <Menu
            class="machine-submenu"
            label={`${providerLabel(prov().provider)} VM sizes`}
            anchor={p.activeSubmenu!.anchor}
            placement="right-start"
            width={296}
            onClose={() => p.onSubmenuChange(undefined)}
          >
            <div class="machine-section-label">
              New {providerLabel(prov().provider)} VM · {p.subtitle ?? "starts on send"}
            </div>
            <For each={providerAllowedSizes(prov(), p.catalog)}>
              {(s) => {
                const target = () => formatAutoManagedTarget(prov().provider, s.size);
                const chosen = () => p.selectedTarget === target();
                return (
                  <button
                    type="button"
                    role="menuitem"
                    data-size={s.size}
                    class={`menu-item machine-size-option ${chosen() ? "on" : ""}`}
                    aria-pressed={chosen()}
                    onClick={() => p.onSelectSize(prov(), s)}
                  >
                    <span class="machine-size-main">
                      <span class="menu-title">{sizeLabel(s.size)}</span>
                      <span class="machine-inline-note">{compactSizeSpec(s)}</span>
                    </span>
                    <Show when={is24hCommitmentSize(s)}>
                      <span class="machine-size-badge" title="24-hour minimum billing lease required by provider">
                        24h min
                      </span>
                    </Show>
                    <span class="machine-size-rate">{usdPerHour(s.usd_per_hour)}</span>
                  </button>
                );
              }}
            </For>
          </Menu>
        )}
      </Show>
    </Show>
  );
}

export function AgentSpawnedVmsToggle(p: {
  count: number;
  expanded: boolean;
  hasSelected?: boolean;
  onToggle: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      class={`menu-item machine-agent-vms-toggle ${p.hasSelected && !p.expanded ? "on" : ""}`}
      aria-expanded={p.expanded}
      onClick={(e) => {
        e.stopPropagation();
        p.onToggle();
      }}
    >
      <span class={`menu-ico machine-disclosure-chevron ${p.expanded ? "open" : ""}`} aria-hidden="true">
        <ChevronRight size={12} />
      </span>
      <span class="menu-col">
        <span class="menu-title">Agent-spawned VMs</span>
        <span class="machine-inline-note">{p.count}</span>
      </span>
    </button>
  );
}

/** Dismiss an open provider submenu when hovering onto any non-provider row in the parent menu. */
export function dismissSubmenuOnSiblingHover(
  e: MouseEvent,
  active: ActiveProviderSubmenu | undefined,
  onClear: () => void,
) {
  if (!active) return;
  const target = e.target instanceof Element ? e.target : null;
  if (!target) return;
  if (target.closest(".machine-submenu")) return;
  if (target.closest(".machine-provider-trigger")) return;
  if (target.closest(".menu-item")) onClear();
}
