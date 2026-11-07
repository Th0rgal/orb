import { Show } from "solid-js";
import { ProvidersIcon } from "./icons";

/**
 * Shared provider brand resolution across desktop, iOS, and Android.
 * Spec: shared/orb-spec/fixtures/provider-logos.json
 */
export function resolveProviderBrand(type: string, name?: string): string | undefined {
  const key = type.toLowerCase();
  const combined = `${key} ${name?.toLowerCase() ?? ""}`;
  if (/hermes/.test(key)) return "hermes";
  if (/spark|nvidia|local/.test(combined)) return "nvidia";
  if (/ethereum|\bef\b/.test(combined)) return "ethereum";
  if (/\bparticle\b|particle[._-]?ai/.test(combined)) return "particle";
  if (/anthropic|claude/.test(key)) return "anthropic";
  if (/openai|codex|chatgpt/.test(key)) return "openai";
  if (/kimi|moonshot/.test(key)) return "kimi";
  if (/grok/.test(key)) return "grok";
  if (/cursor/.test(key)) return "cursor";
  if (/xai/.test(key)) return "xai";
  if (/meta|muse|llama/.test(key)) return "meta";
  if (/minimax/.test(key)) return "minimax";
  if (/mistral|vibe/.test(key)) return "mistral";
  if (/google|antigravity|gemini/.test(key)) return "google";
  if (/z[._-]?ai|zhipu|glm/.test(key)) return "zai";
  return undefined;
}

/** Bundled provider assets; never load branding from a remote host. */
export function ProviderLogo(p: { type: string; name?: string }) {
  const brand = () => resolveProviderBrand(p.type, p.name);
  return <span class="provider-logo" aria-hidden="true"><Show when={brand() === "hermes"} fallback={<Show when={brand()} fallback={<ProvidersIcon size={19} />}>
    {name => <span style={{ "mask-image": `url(/provider-icons/${name()}.svg)`, "-webkit-mask-image": `url(/provider-icons/${name()}.svg)` }} />}
  </Show>}><img src="/hermes.png" alt="" style={{width:"100%",height:"100%","object-fit":"contain"}} /></Show></span>;
}
