import { Show } from "solid-js";
import { ProvidersIcon } from "./icons";

/** Bundled provider assets; never load branding from a remote host. */
export function ProviderLogo(p: { type: string; name?: string }) {
  const brand = () => {
    const key = p.type.toLowerCase();
    if (/spark|nvidia|local/.test(`${key} ${p.name?.toLowerCase() ?? ""}`)) return "nvidia";
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
  };
  return <span class="provider-logo" aria-hidden="true"><Show when={/hermes/.test(p.type)} fallback={<Show when={brand()} fallback={<ProvidersIcon size={19} />}>
    {name => <span style={{ "mask-image": `url(/provider-icons/${name()}.svg)`, "-webkit-mask-image": `url(/provider-icons/${name()}.svg)` }} />}
  </Show>}><img src="/hermes.png" alt="" style={{width:"100%",height:"100%","object-fit":"contain"}} /></Show></span>;
}
