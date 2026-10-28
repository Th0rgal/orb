// Imported before App, API and module-level stores. Only kernel readiness opens
// the dynamic-import boundary; a failure remains visible and can be retried.
export function startApp(root: HTMLElement, initialize: () => Promise<void>, mount: () => Promise<void>): void {
  let pending = false;
  async function attempt() {
    if (pending) return;
    pending = true;
    root.replaceChildren();
    const card = document.createElement("div");
    card.className = "startup-card";
    card.setAttribute("role", "status");
    card.textContent = "Starting Orb…";
    root.append(card);
    try {
      await initialize();
    } catch {
      card.setAttribute("role", "alert");
      card.textContent = "Orb could not start. Please retry.";
      const retry = document.createElement("button");
      retry.textContent = "Retry";
      retry.addEventListener("click", () => void attempt());
      card.append(retry);
      pending = false;
      return;
    }
    try {
      await mount();
    } catch {
      root.replaceChildren();
      card.setAttribute("role", "alert");
      card.textContent = "Orb could not open. Please reload.";
      const reload = document.createElement("button");
      reload.textContent = "Reload";
      reload.addEventListener("click", () => location.reload());
      card.append(reload);
      root.append(card);
    }
  }
  void attempt();
}
