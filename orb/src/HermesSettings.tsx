import { For, Show, createSignal, onMount } from "solid-js";
import { getHermesSettings, updateHermesSettings, type HermesSettingsState } from "./cloudAgentApi";
import { isConnected } from "./api";
import { Select } from "./Select";
import { ErrorNotice } from "./ErrorNotice";
import { ProviderLogo } from "./ProviderLogo";

export function HermesSettings() {
  const [state, setState] = createSignal<HermesSettingsState | null>(null);
  const [loading, setLoading] = createSignal(true);
  const [saving, setSaving] = createSignal(false);
  const [restarting, setRestarting] = createSignal(false);
  const [error, setError] = createSignal("");
  const [notice, setNotice] = createSignal("");

  const [defaultModel, setDefaultModel] = createSignal("");
  const [reasoningEffort, setReasoningEffort] = createSignal("");
  const [useRouter, setUseRouter] = createSignal(true);
  const [memoryEnabled, setMemoryEnabled] = createSignal(true);
  const [userProfileEnabled, setUserProfileEnabled] = createSignal(true);
  const [memoryCharLimit, setMemoryCharLimit] = createSignal(8000);
  const [userCharLimit, setUserCharLimit] = createSignal(4000);
  const [compressionEnabled, setCompressionEnabled] = createSignal(true);
  const [compressionThreshold, setCompressionThreshold] = createSignal(0.5);
  const [telegramProgress, setTelegramProgress] = createSignal("new");
  const [telegramCleanup, setTelegramCleanup] = createSignal(false);
  const [soulMarkdown, setSoulMarkdown] = createSignal("");

  const applyState = (next: HermesSettingsState) => {
    setState(next);
    setDefaultModel(next.default_model ?? "");
    setReasoningEffort(next.reasoning_effort ?? "");
    setUseRouter(Boolean(next.use_sandboxed_router));
    setMemoryEnabled(Boolean(next.memory_enabled));
    setUserProfileEnabled(Boolean(next.user_profile_enabled));
    setMemoryCharLimit(next.memory_char_limit ?? 8000);
    setUserCharLimit(next.user_char_limit ?? 4000);
    setCompressionEnabled(Boolean(next.compression_enabled));
    setCompressionThreshold(next.compression_threshold ?? 0.5);
    setTelegramProgress(next.telegram_tool_progress || "new");
    setTelegramCleanup(Boolean(next.telegram_cleanup_progress));
    setSoulMarkdown(next.soul_markdown ?? "");
  };

  const load = async () => {
    if (!isConnected()) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    try {
      applyState(await getHermesSettings());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  onMount(() => {
    void load();
  });

  const save = async (restart = false) => {
    if (saving() || restarting()) return;
    if (restart) setRestarting(true);
    else setSaving(true);
    setError("");
    setNotice("");
    try {
      const updated = await updateHermesSettings({
        default_model: defaultModel().trim(),
        reasoning_effort: reasoningEffort(),
        use_sandboxed_router: useRouter(),
        memory_enabled: memoryEnabled(),
        user_profile_enabled: userProfileEnabled(),
        memory_char_limit: Number(memoryCharLimit()) || 8000,
        user_char_limit: Number(userCharLimit()) || 4000,
        compression_enabled: compressionEnabled(),
        compression_threshold: Number(compressionThreshold()) || 0.5,
        telegram_tool_progress: telegramProgress(),
        telegram_cleanup_progress: telegramCleanup(),
        soul_markdown: soulMarkdown(),
        restart_service: restart,
      });
      applyState(updated);
      setNotice(restart ? "Saved configuration and restarted Hermes service." : "Saved Hermes configuration.");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
      setRestarting(false);
    }
  };

  const modelOptions = () => {
    const list = state()?.models?.filter(m => m.id) ?? [];
    const cur = defaultModel().trim();
    if (cur && !list.some(m => m.id === cur)) {
      return [{ id: cur, name: `${cur} (current)` }, ...list];
    }
    return list;
  };

  return (
    <div class="s-body settings-body" aria-label="Hermes settings">
      <div class="s-inner">
        <h2>Hermes</h2>
        <Show
          when={isConnected()}
          fallback={
            <section class="s-sec">
              <div class="s-card">
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">Not connected</div>
                    <div class="s-row-desc">Connect to Core in Client settings to configure Hermes.</div>
                  </div>
                </div>
              </div>
            </section>
          }
        >
          <Show when={error()}>
            <ErrorNotice error={error()} onDismiss={() => setError("")} />
          </Show>
          <Show when={loading() && !state()}>
            <section class="s-sec">
              <div class="s-card">
                <div class="s-row" role="status">Loading Hermes settings…</div>
              </div>
            </section>
          </Show>
          <Show when={state()}>
            {s => (
              <>
                <section class="s-sec" aria-label="Hermes runtime">
                  <h3>Runtime &amp; Gateway</h3>
                  <div class="s-card">
                    <div class="s-row">
                      <ProviderLogo type="hermes" />
                      <div class="s-row-text">
                        <div class="s-row-title">
                          Paloma · {s().runtime?.service_name || "hermes-agent.service"}
                        </div>
                        <div class="s-row-desc">
                          Service: {s().runtime?.service_state || "unknown"} · Gateway: {s().runtime?.gateway_state || "unknown"} · API: {s().runtime?.api_server_healthy ? "Healthy" : "Unreachable"}
                          <Show when={typeof s().runtime?.active_runs === "number"}> · Active runs: {s().runtime?.active_runs}</Show>
                        </div>
                      </div>
                      <div class="s-row-ctrl">
                        <button class="s-btn" disabled={loading() || saving() || restarting()} onClick={() => void load()}>
                          Refresh
                        </button>
                        <button class="s-btn" disabled={saving() || restarting()} onClick={() => void save(true)}>
                          {restarting() ? "Restarting…" : "Restart service"}
                        </button>
                      </div>
                    </div>
                    <Show when={s().sessions?.available}>
                      <div class="s-row">
                        <div class="s-row-text">
                          <div class="s-row-title">Session store</div>
                          <div class="s-row-desc">
                            {s().sessions?.total_sessions ?? 0} total sessions · {s().sessions?.active_sessions_24h ?? 0} active in 24h · {(s().sessions?.total_tokens ?? 0).toLocaleString()} tokens recorded
                          </div>
                        </div>
                        <div class="s-row-ctrl">
                          <span class="s-row-desc">{s().home_dir}</span>
                        </div>
                      </div>
                    </Show>
                  </div>
                </section>

                <section class="s-sec" aria-label="Hermes model and router">
                  <h3>Model &amp; Router</h3>
                  <div class="s-card">
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Route through sandboxed.sh router</div>
                        <div class="s-row-desc">
                          Use Core’s unified LLM proxy so Hermes can run builtin chains (like builtin/private) and all configured provider models.
                        </div>
                      </div>
                      <div class="s-row-ctrl">
                        <button
                          class={`toggle ${useRouter() ? "on" : ""}`}
                          role="switch"
                          aria-label="Route through sandboxed.sh router"
                          aria-checked={useRouter()}
                          onClick={() => setUseRouter(!useRouter())}
                        />
                      </div>
                    </div>
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Default model</div>
                        <div class="s-row-desc">
                          Used when a Hermes conversation starts with “Profile default”. Can be overridden per mission or mid-conversation.
                        </div>
                      </div>
                      <div class="s-row-ctrl">
                        <Select
                          aria-label="Default Hermes model"
                          value={defaultModel()}
                          onChange={e => setDefaultModel(e.currentTarget.value)}
                        >
                          <For each={modelOptions()}>
                            {m => <option value={m.id}>{m.name || m.displayName || m.id}</option>}
                          </For>
                        </Select>
                      </div>
                    </div>
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Default reasoning effort</div>
                        <div class="s-row-desc">
                          Default thinking budget in config.yaml. Individual turns in Orb can override this without forking the session.
                        </div>
                      </div>
                      <div class="s-row-ctrl">
                        <Select
                          aria-label="Default reasoning effort"
                          value={reasoningEffort()}
                          onChange={e => setReasoningEffort(e.currentTarget.value)}
                        >
                          <For each={s().efforts ?? []}>
                            {eff => <option value={eff.id}>{eff.name || eff.displayName || eff.id || "Default"}</option>}
                          </For>
                        </Select>
                      </div>
                    </div>
                  </div>
                </section>

                <section class="s-sec" aria-label="Hermes memory and context">
                  <h3>Memory &amp; Context Compression</h3>
                  <div class="s-card">
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Persistent memory (MEMORY.md)</div>
                        <div class="s-row-desc">Allow Hermes to read and update long-term notes across sessions.</div>
                      </div>
                      <div class="s-row-ctrl">
                        <input
                          class="s-input"
                          type="number"
                          min={500}
                          max={200000}
                          aria-label="Memory character limit"
                          title="Character limit"
                          style={{ width: "96px" }}
                          value={memoryCharLimit()}
                          onInput={e => setMemoryCharLimit(Number(e.currentTarget.value))}
                        />
                        <button
                          class={`toggle ${memoryEnabled() ? "on" : ""}`}
                          role="switch"
                          aria-label="Persistent memory"
                          aria-checked={memoryEnabled()}
                          onClick={() => setMemoryEnabled(!memoryEnabled())}
                        />
                      </div>
                    </div>
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">User profile memory (USER.md)</div>
                        <div class="s-row-desc">Maintain user preferences and environment conventions across conversations.</div>
                      </div>
                      <div class="s-row-ctrl">
                        <input
                          class="s-input"
                          type="number"
                          min={500}
                          max={200000}
                          aria-label="User profile character limit"
                          title="Character limit"
                          style={{ width: "96px" }}
                          value={userCharLimit()}
                          onInput={e => setUserCharLimit(Number(e.currentTarget.value))}
                        />
                        <button
                          class={`toggle ${userProfileEnabled() ? "on" : ""}`}
                          role="switch"
                          aria-label="User profile memory"
                          aria-checked={userProfileEnabled()}
                          onClick={() => setUserProfileEnabled(!userProfileEnabled())}
                        />
                      </div>
                    </div>
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Context auto-compression</div>
                        <div class="s-row-desc">Automatically summarize older turns when context usage crosses the threshold (0.10 – 0.95).</div>
                      </div>
                      <div class="s-row-ctrl">
                        <input
                          class="s-input"
                          type="number"
                          step="0.05"
                          min={0.1}
                          max={0.95}
                          aria-label="Compression threshold"
                          style={{ width: "84px" }}
                          value={compressionThreshold()}
                          onInput={e => setCompressionThreshold(Number(e.currentTarget.value))}
                        />
                        <button
                          class={`toggle ${compressionEnabled() ? "on" : ""}`}
                          role="switch"
                          aria-label="Context auto-compression"
                          aria-checked={compressionEnabled()}
                          onClick={() => setCompressionEnabled(!compressionEnabled())}
                        />
                      </div>
                    </div>
                  </div>
                </section>

                <section class="s-sec" aria-label="Hermes channels and persona">
                  <h3>Channels &amp; Persona (SOUL.md)</h3>
                  <div class="s-card">
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Telegram tool progress</div>
                        <div class="s-row-desc">How Hermes reports intermediate tool calls in Telegram chats.</div>
                      </div>
                      <div class="s-row-ctrl">
                        <Select
                          aria-label="Telegram tool progress"
                          value={telegramProgress()}
                          onChange={e => setTelegramProgress(e.currentTarget.value)}
                        >
                          <option value="off">Off</option>
                          <option value="new">New message</option>
                          <option value="edit">Edit in place</option>
                          <option value="all">All updates</option>
                        </Select>
                      </div>
                    </div>
                    <div class="s-row">
                      <div class="s-row-text">
                        <div class="s-row-title">Clean up Telegram progress messages</div>
                        <div class="s-row-desc">Delete intermediate tool status messages once the final reply is sent.</div>
                      </div>
                      <div class="s-row-ctrl">
                        <button
                          class={`toggle ${telegramCleanup() ? "on" : ""}`}
                          role="switch"
                          aria-label="Clean up Telegram progress messages"
                          aria-checked={telegramCleanup()}
                          onClick={() => setTelegramCleanup(!telegramCleanup())}
                        />
                      </div>
                    </div>
                    <div class="s-row" style={{ "flex-direction": "column", "align-items": "stretch", gap: "8px" }}>
                      <div class="s-row-text">
                        <div class="s-row-title">Persona &amp; instructions (SOUL.md)</div>
                        <div class="s-row-desc">{s().soul_path}</div>
                      </div>
                      <textarea
                        class="s-input"
                        aria-label="SOUL.md content"
                        rows={8}
                        style={{ width: "100%", "font-family": "var(--mono)", "font-size": "12px", resize: "vertical" }}
                        value={soulMarkdown()}
                        onInput={e => setSoulMarkdown(e.currentTarget.value)}
                      />
                    </div>
                    <div class="s-row">
                      <span class="s-row-desc" role="status">{notice()}</span>
                      <div class="s-row-ctrl">
                        <button class="s-btn" disabled={saving() || restarting()} onClick={() => void save(false)}>
                          {saving() ? "Saving…" : "Save"}
                        </button>
                        <button class="s-btn primary" disabled={saving() || restarting()} onClick={() => void save(true)}>
                          {restarting() ? "Restarting…" : "Save & Restart"}
                        </button>
                      </div>
                    </div>
                  </div>
                </section>
              </>
            )}
          </Show>
        </Show>
      </div>
    </div>
  );
}
