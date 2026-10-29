// Imported before App, API and module-level stores. Only kernel readiness opens
// the dynamic-import boundary; a failure remains visible and can be retried.
// Avoid painting a placeholder before WASM resolves on fast startups so mounting
// App triggers zero cumulative layout shift (CLS = 0); surface a status card only
// if WASM initialization stalls past 180ms or fails.
export function startApp(root: HTMLElement, initialize: () => Promise<void>, mount: () => Promise<void>): void {
  let pending = false;
  function mkCard(): HTMLDivElement {
    const card = document.createElement("div");
    card.className = "startup-card";
    card.style.cssText = "position:fixed;inset:0;margin:15vh auto auto;max-width:30rem;padding:2rem;box-sizing:border-box";
    return card;
  }
  function mkBtn(label: string, onClick: () => void): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.textContent = label;
    btn.style.cssText = "display:block;margin-top:1rem";
    btn.addEventListener("click", onClick);
    return btn;
  }
  async function attempt(immediateStatus: boolean) {
    if (pending) return;
    pending = true;
    root.replaceChildren();
    const card = mkCard();
    card.setAttribute("role", "status");
    card.textContent = "Starting Orb…";
    let timer: ReturnType<typeof setTimeout> | undefined;
    if (immediateStatus) {
      root.append(card);
    } else {
      timer = setTimeout(() => {
        if (pending && !card.isConnected && root.childElementCount === 0) root.append(card);
      }, 180);
    }
    try {
      await initialize();
      if (timer !== undefined) clearTimeout(timer);
    } catch {
      if (timer !== undefined) clearTimeout(timer);
      card.setAttribute("role", "alert");
      card.textContent = "Orb could not start. Please retry.";
      card.append(mkBtn("Retry", () => void attempt(true)));
      if (!card.isConnected) root.replaceChildren(card);
      pending = false;
      return;
    }
    try {
      await mount();
    } catch {
      root.replaceChildren();
      card.setAttribute("role", "alert");
      card.textContent = "Orb could not open. Please reload.";
      card.append(mkBtn("Reload", () => location.reload()));
      root.append(card);
    }
  }
  void attempt(false);
}
