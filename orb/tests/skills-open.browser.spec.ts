import { expect, test } from "@playwright/test";

// Skills opens from the Library index; the 46 skill bodies (for drift) load behind it.
// Before: the first row waited for every body (~1.85 s at 150 ms per request).
test("Skills shows rows before every skill body has loaded", async ({ page }) => {
  await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb.selectedConversation", "settings"); });
  const names = Array.from({ length: 46 }, (_, i) => `skill-${String(i).padStart(2, "0")}`);
  let active = 0; const queue: (() => void)[] = [];
  const slot = async () => { if (active >= 6) await new Promise<void>(r => queue.push(r)); active++; };
  const release = () => { active--; queue.shift()?.(); };
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.startsWith("/api/library") || path.startsWith("/api/projects")) { await slot(); await new Promise(r => setTimeout(r, 150)); release(); }
    if (path === "/api/library/skill") return route.fulfill({ json: names.map(name => ({ name, description: `Does ${name}.`, path: `skill/${name}` })) });
    const m = path.match(/^\/api\/library\/skill\/([^/]+)$/);
    if (m) return route.fulfill({ json: { name: m[1], description: `Does ${m[1]}.`, path: `skill/${m[1]}`, content: `---\nname: ${m[1]}\ndescription: Does ${m[1]}.\n---\n# ${m[1]}\n`, files: [], references: [] } });
    if (path === "/api/library/status") return route.fulfill({ json: { path: "/lib", remote: "git@github.com:Th0rgal/sandboxed-library.git", branch: "main", clean: true, ahead: 0, behind: 0, modified_files: [], last_synced_at: Math.floor(Date.now() / 1000) - 120 } });
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "a", title: "A" }, { slug: "b", title: "B" }] } });
    return route.fulfill({ json: path === "/api/control/missions" ? [] : [] });
  });
  await page.goto("/");
  await page.locator('[data-settings-section="agents"]').waitFor();
  const t0 = Date.now();
  await page.locator('[data-settings-section="agents"]').click();
  await page.locator(".skills-item").first().waitFor({ timeout: 20000 });
  const paint = Date.now() - t0;
  await page.locator(".skills-item[data-skill]").first().waitFor({ timeout: 20000 });
  const first = Date.now() - t0;
  console.log(`PERF first-paint ${paint}ms first-row ${first}ms`);
  expect(paint).toBeLessThan(first);
  expect(first).toBeLessThan(1000);
  await expect(page.locator(".skills-item[data-skill]")).toHaveCount(46);
});
