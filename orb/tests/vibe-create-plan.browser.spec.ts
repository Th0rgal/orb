import { expect, test } from "@playwright/test";

for (const machine of ["core", "ashur"]) {
  for (const scenario of [
    { name: "plan", prompt: "  /plan\nInspect the repository", plan: true },
    { name: "build", prompt: "Implement the change", plan: false },
    { name: "ordinary slash prefix", prompt: "/planet Inspect the repository", plan: false },
  ]) {
    test(`Vibe ${scenario.name} creates the correct durable mode on ${machine}`, async ({ page }) => {
      const posts: Record<string, unknown>[] = [];
      await page.addInitScript(destination => {
        localStorage.setItem("orb.apiUrl", location.origin);
        localStorage.setItem("orb.jwt", "vibe-plan-create-test");
        localStorage.setItem("orb.machine", destination);
        localStorage.setItem("orb.harnessPick", JSON.stringify({ backend: "vibe", model: "mistral/mistral-vibe-cli-latest" }));
      }, machine);
      await page.route("**/api/**", route => {
        const request = route.request(), path = new URL(request.url()).pathname;
        if (path === "/api/control/missions" && request.method() === "POST") {
          posts.push(request.postDataJSON());
          // Capture the real creation request without starting a conversation.
          return route.fulfill({ status: 503, body: "Test admission declined" });
        }
        if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
        const json = path === "/api/projects" ? { projects: [{ slug: "default", title: "Default" }] }
          : path === "/api/backends" ? [{ id: "vibe", name: "Mistral Vibe", native_plan: true }]
          : path === "/api/providers/backend-models" ? { backends: { vibe: [{ value: "mistral/mistral-vibe-cli-latest", label: "Mistral Vibe" }] } }
          : path === "/api/remote-nodes" ? { enabled: true, nodes: machine === "ashur" ? [{ id: "ashur", status: "online", cordoned: false }] : [], remote_launch: { typed: true, harnesses: ["vibe"], proxy_url_configured: true } }
          : path.endsWith("/files") ? { entries: [] }
          : path.endsWith("/crons") ? { jobs: [] }
          : path.endsWith("/controller") ? { job: null, runs: [] } : [];
        return route.fulfill({ json });
      });
      await page.goto("/");
      await expect(page.getByTitle("Harness", { exact: true })).toHaveText("Mistral Vibe");
      await expect(page.locator(".na-meta")).toContainText(machine === "core" ? "Core (agent-core)" : "ashur");
      const input = page.getByPlaceholder("Describe a task, / for commands, @ for context");
      await input.fill(scenario.prompt);
      await input.press("Enter");
      await expect.poll(() => posts.length).toBe(1);
      expect(posts[0]).toMatchObject({ backend: "vibe", model_override: "mistral/mistral-vibe-cli-latest" });
      if (scenario.plan) {
        expect(posts[0].prompt).toBe(scenario.prompt.trim());
        expect(posts[0].agent).toBe("plan");
      } else {
        expect(posts[0].prompt).toBe(scenario.prompt);
        expect(posts[0]).not.toHaveProperty("agent");
      }
      if (machine === "ashur") expect(posts[0].remote_node_id).toBe("ashur");
      else expect(posts[0]).not.toHaveProperty("remote_node_id");
    });
  }
}
