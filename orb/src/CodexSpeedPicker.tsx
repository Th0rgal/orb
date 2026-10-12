import {createEffect, createSignal, onCleanup, Show} from 'solid-js';
import {api, connectionVersion, type CodexServiceTier} from './api';
import {localCodexSpeedOptions} from './localAgents';
import {Picker} from './Picker';
import * as Ic from './icons';

type SpeedOption = {id: CodexServiceTier; available: boolean; reason?: string};
export const speedLabel = (tier?: CodexServiceTier) => tier === 'ultrafast' ? 'Ultrafast' : tier === 'fast' ? 'Fast' : 'Standard';
export const missionSpeed = (mission: {service_tier?: CodexServiceTier | null; fast_mode?: boolean}) => mission.service_tier ?? (mission.fast_mode ? 'fast' : 'standard');
export async function requireSpeedSupport(model: string, tier: CodexServiceTier, missionId?: string, local = false) {
  if (tier === 'standard') return;
  const data = local ? await localCodexSpeedOptions(model) : await api<{tiers: SpeedOption[]}>(`/api/control/codex-speed?model=${encodeURIComponent(model)}${missionId ? `&mission_id=${encodeURIComponent(missionId)}` : ''}`);
  const option = data.tiers.find(item => item.id === tier);
  if (!option?.available) throw new Error(option?.reason ?? 'This speed is not available on the connected subscriptions.');
}
export function CodexSpeedPicker(p: {model: string; value: CodexServiceTier; missionId?: string; local?: boolean; disabled?: boolean; onChange: (tier: CodexServiceTier) => void}) {
  const [open, setOpen] = createSignal(false);
  const [options, setOptions] = createSignal<SpeedOption[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal('');
  const [retry, setRetry] = createSignal(0);
  createEffect(() => {
    const model = p.model, mission = p.missionId, local = p.local;
    retry(); connectionVersion();
    let current = true;
    setError(''); setOptions([]); setLoading(false);
    if (!open()) return;
    setLoading(true);
    const request = local ? localCodexSpeedOptions(model) : api<{tiers:SpeedOption[]}>(`/api/control/codex-speed?model=${encodeURIComponent(model)}${mission ? `&mission_id=${encodeURIComponent(mission)}` : ''}`)
    void request.then(data => {if(current) setOptions(data.tiers);})
      .catch(e => {if(current) setError(String(e));})
      .finally(() => {if(current) setLoading(false);});
    // An old model/connection response cannot unlock a new selection.
    onCleanup(() => { current = false; });
  });
  return <div class="under-model-wrap model-wrap">
    <button type="button" class="model under-model" disabled={p.disabled} aria-label={`Speed: ${speedLabel(p.value)}`} aria-haspopup="listbox" aria-expanded={open()} title={p.missionId ? "Codex speed · applies from the next turn" : "Codex speed for this agent"} onClick={() => setOpen(!open())}>
      {speedLabel(p.value)} <Ic.ChevronDown size={12}/>
    </button>
    <Show when={open()}><Picker label="Codex speed" searchable={false} placement="top-start" selected={p.value} loading={loading()} error={error()} onRetry={() => setRetry(n => n + 1)}
      items={(['standard','fast','ultrafast'] as const).map(id => {
        const option=options().find(item => item.id===id);
        return {id,label:speedLabel(id),disabled:!option?.available,description:option?.reason ?? (id==='standard' ? 'Normal subscription usage' : id==='fast' ? 'Compatible subscriptions · higher usage' : 'Eligible subscriptions · 8× included usage')};
      })} onClose={() => setOpen(false)} onSelect={value => {setOpen(false);p.onChange(value as CodexServiceTier);}}/></Show>
  </div>;
}
