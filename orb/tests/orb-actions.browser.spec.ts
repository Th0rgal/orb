import { test, expect, type Page } from "@playwright/test";

const MISSION_ID = "3f2a91c4-8b7d-4e21-9a0c-5d6e7f801234";
const DONE_ID = "8c11ee52-0000-4aaa-9bbb-cccccccccccc";

const missions = [
  {
    id: MISSION_ID,
    title: "Lido SRv3 report",
    status: "active",
    history: [],
    backend: "codex",
    model_override: "gpt-6-astra",
    // Deliberately different ids: none of these may reach the clipboard.
    remote_job: { job_id: "job_9f81c0aa", node_id: "dgx-spark", phase: "running" },
    remote_node_id: "dgx-spark",
    workspace_name: "lido-srv3",
    created_at: "",
    updated_at: "",
  },
  { id: DONE_ID, title: "Earlier report", status: "completed", history: [], created_at: "", updated_at: "" },
];

type Options = { clipboard?: "ok" | "broken"; entries?: Array<{ name: string; kind: string }>; capAt?: { active: number; cap: number } };

async function setup(page: Page, options: Options = {}) {
  const posts: any[] = [];
  const writes: any[] = [];
  const grants: any[] = [];
  await page.addInitScript((broken: boolean) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
    localStorage.setItem("orb.harnessPick", JSON.stringify({ backend: "codex", model: "gpt-6-astra" }));
    (window as any).__copied = [];
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text: string) => {
          if (broken) throw new Error("NotAllowedError");
          (window as any).__copied.push(text);
        },
      },
    });
  }, options.clipboard === "broken");

  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    if(path === "/api/control/cyber-capabilities") return route.fulfill({json:{version:2}});
    if(path === "/api/model-routing/chains") return route.fulfill({json:[{id:"builtin/smart",name:"Smart (Default)"}]});
    if (path === "/api/control/missions" && request.method() === "POST") {
      posts.push(request.postDataJSON());
      if (options.capAt) {
        return route.fulfill({
          status: 429,
          body: JSON.stringify({ error: "parallel_missions_cap", cap: options.capAt.cap, active: options.capAt.active }),
        });
      }
      return route.fulfill({ json: { ...missions[0], id: "new-mission" } });
    }
    if (path.endsWith("/file") && request.method() === "PUT") {
      writes.push(request.postDataJSON());
      return route.fulfill({ json: { path: request.postDataJSON().path, bytes: 0 } });
    }
    if (path.endsWith("/grant")) {
      if (request.method() === "POST") grants.push(request.postDataJSON());
      return route.fulfill({ json: { slug: "test", grant: { parallel_missions: 2, autonomy_level: "act_reversible", merge_authority: "owner" } } });
    }
    if (path === "/api/settings") return route.fulfill({ json: { max_parallel_missions: 4, max_concurrent_tasks: 8 } });
    if (path.endsWith("/file") && request.method() === "GET") return route.fulfill({ json: { content: "" } });

    const json =
      path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "claudecode", name: "Claude Code" }, { id: "codex", name: "Codex" }, { id: "opencode", name: "OpenCode" }]
      : path === "/api/providers/backend-models" ? { backends: {
          claudecode: [{ value: "claude-opus-5", label: "Anthropic — Claude Opus 5" }],
          codex: [{ value: "gpt-6-astra", label: "OpenAI — GPT-6 Astra" }],
          opencode: [{ value: "xai/grok-4.6", label: "xAI — Grok 4.6" }],
        } }
      : path === "/api/remote-nodes" ? { enabled: true, nodes: [], remote_launch: { typed: true, harnesses: ["codex"], proxy_url_configured: true } }
      : path === "/api/control/missions" ? (url.searchParams.get("project") === "test" ? missions : [])
      : path.endsWith("/files") ? { entries: options.entries ?? [{ name: "reference", kind: "dir" }] }
      : path.endsWith("/crons") ? { jobs: [] }
      : { job: null, runs: [] };
    await route.fulfill({ json });
  });
  await page.goto("/");
  return { posts, writes, grants };
}

const expandProject = async (page: Page) => {
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await expect(page.getByRole("button", { name: /Lido SRv3 report/ })).toBeVisible();
};
const copied = (page: Page) => page.evaluate(() => (window as any).__copied as string[]);

// ---------------------------------------------------------------- feature 1

test("right-click an agent row: Copy mission ID copies the raw UUID and changes nothing", async ({ page }) => {
  await setup(page);
  await expandProject(page);

  const row = page.getByRole("button", { name: /Lido SRv3 report/ });
  await expect(row).not.toHaveClass(/active/);
  await row.click({ button: "right" });

  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();
  // Identity actions only — no project/file creation leaking onto an agent row.
  await expect(menu.getByRole("menuitem")).toHaveText(["Delete agent…", /^Fork conversation/, "Move", "Rename", "Copy mission ID"]);

  await menu.getByRole("menuitem", { name: "Copy mission ID" }).click();
  expect(await copied(page)).toEqual([MISSION_ID]);
  await expect(menu).not.toBeVisible();

  // Context selection highlights the row without opening its conversation.
  await expect(row).toHaveClass(/active/);
  await expect(page.locator(".tb-title")).toHaveText("New Agent");
  await expect(page.getByPlaceholder("Describe a task, / for commands, @ for context")).toBeVisible();
});

test("finished agent rows offer the same copy, and it is never an execution id", async ({ page }) => {
  await setup(page);
  await expandProject(page);

  const done = page.getByRole("button", { name: /Earlier report/ });
  await done.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Copy mission ID" }).click();

  const values = await copied(page);
  expect(values).toEqual([DONE_ID]);
  expect(values[0]).not.toContain("m:");
  expect(values[0]).not.toBe("job_9f81c0aa");
  await expect(done).toHaveClass(/active/);
  await expect(page.locator(".tb-title")).toHaveText("New Agent");
});

test("a refused clipboard write is reported, not swallowed", async ({ page }) => {
  await setup(page, { clipboard: "broken" });
  await expandProject(page);
  await page.getByRole("button", { name: /Lido SRv3 report/ }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Copy mission ID" }).click();

  const alert = page.getByRole("alert");
  await expect(alert).toBeVisible();
  await expect(alert).toContainText(/refused/i);
  expect(await copied(page)).toEqual([]);
});

// ---------------------------------------------------------------- feature 2

test("reference subfolder: hover reveals +, whose menu creates agents, crons and files", async ({ page }) => {
  const { writes, posts } = await setup(page);
  await expandProject(page);

  const folder = page.locator(".row.folder", { hasText: "reference" });
  const plus = folder.getByRole("button", { name: "Folder actions for reference" });
  // Hidden until the row is hovered or focused.
  expect(await plus.evaluate((el) => getComputedStyle(el).opacity)).toBe("0");
  await folder.hover();
  await expect(plus).toHaveCSS("opacity", "1");
  // The disclosure control is a sibling button, never nested inside another.
  await expect(folder.locator("button button")).toHaveCount(0);

  await plus.click();
  const menu = page.getByRole("menu");
  await expect(menu.getByRole("menuitem")).toHaveText(["New agent", "Cloud agent", "New cron", "New file", "New folder", "Rename", "Move…", "Cut", "Copy", "Delete…"]);

  await menu.getByRole("menuitem", { name: "New file" }).click();
  await page.getByLabel("File name").fill("spec");
  await page.getByRole("button", { name: "Create" }).click();

  // Written through the core's project-file API, under the folder, with .md.
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toEqual({ path: "reference/spec.md", content: "" });
  // No mission and no cron was needed to create a file.
  expect(posts).toEqual([]);

  // The parent is expanded and the new file is opened in the Markdown view.
  await expect(page.locator(".pf-path")).toHaveText("test/reference/spec.md");
  await expect(page.getByRole("button", { name: "Edit" })).toBeVisible();
});

test("a created reference file opens in Markdown, autosaves, and toggles with Cmd+/", async ({ page }) => {
  const { writes } = await setup(page, { entries: [{ name: "notes.md", kind: "file" }] });
  await expandProject(page);
  await page.getByRole("button", { name: "notes.md" }).click();

  // Preview by default; the shortcut and the button drive the same state, so
  // the title bar hint and the button label always agree.
  await expect(page.locator(".pf-path")).toHaveText("test/notes.md");
  const toggle = page.getByRole("button", { name: "Preview" }).or(page.getByRole("button", { name: "Edit" }));
  await expect(toggle).toHaveText("Edit");
  await expect(page.locator(".tb-kbd")).toHaveText("Source ⌘/");
  await expect(page.locator(".file-view textarea")).toHaveCount(0);

  // ⌘/ reaches core-hosted reference files, not just the local demo files.
  await page.keyboard.press("Meta+/");
  await expect(page.locator(".file-view textarea")).toBeVisible();
  await expect(toggle).toHaveText("Preview");
  await expect(page.locator(".tb-kbd")).toHaveText("Preview ⌘/");

  // Autosave still writes through the core's project-file API.
  await page.locator(".file-view textarea").fill("# Notes\n\nfrom the shortcut");
  await expect.poll(() => writes.length, { timeout: 5000 }).toBe(1);
  expect(writes[0]).toEqual({ path: "notes.md", content: "# Notes\n\nfrom the shortcut" });

  await page.keyboard.press("Meta+/");
  await expect(page.locator(".file-view textarea")).toHaveCount(0);
  await expect(toggle).toHaveText("Edit");
});

test("the project root offers agents and crons first and never file creation", async ({ page }) => {
  const { writes } = await setup(page);
  await page.getByRole("button", { name: "Project actions for Test" }).click();
  const menu = page.getByRole("menu");
  await expect(menu.getByRole("menuitem")).toHaveText([
    "New agent", "Cloud agent", "New cron", "New folder", "Project settings", "Rename", "Archive",
  ]);
  await expect(menu.getByRole("menuitem", { name: "New file" })).toHaveCount(0);
  expect(writes).toEqual([]);
});

test("new file: traversal is refused and an existing name is never overwritten", async ({ page }) => {
  const { writes } = await setup(page, { entries: [{ name: "reference", kind: "dir" }, { name: "notes.md", kind: "file" }] });
  await expandProject(page);
  await page.getByRole("button", { name: "Folder actions for reference" }).click();
  await page.getByRole("menuitem", { name: "New file" }).click();

  const input = page.getByLabel("File name");
  const create = page.getByRole("button", { name: "Create" });

  await input.fill("../escape.md");
  await create.click();
  await expect(page.getByRole("alert")).toContainText("'.' or '..'");
  expect(writes).toEqual([]);

  await input.fill("notes.md");
  await create.click();
  await expect(page.getByRole("alert")).toContainText('"notes.md" already exists here');
  expect(writes).toEqual([]);

  // A valid name still goes through after the refusals.
  await input.fill("plan");
  await create.click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0].path).toBe("reference/plan.md");
});

// ---------------------------------------------------------------- feature 3

test("composer effort: shown after harness and model for Codex, and sent on create", async ({ page }) => {
  const { posts } = await setup(page);
  const picks = page.locator(".picks .model:not(.cyber-pill)");
  await expect(picks).toHaveText(["Codex", "GPT-6 Astra", "Default"]);

  await picks.nth(2).click();
  const menu = page.locator(".picker");
  await expect(menu.locator(".picker-row-copy > span")).toHaveText(["Default", "Low", "Medium", "High", "XHigh", "Max"]);
  await menu.getByRole("option", { name: /High/ }).first().click();
  await expect(picks.nth(2)).toHaveText(/High/);

  await page.getByPlaceholder("Describe a task, / for commands, @ for context").fill("ship it");
  await page.keyboard.press("Enter");
  await expect.poll(() => posts.length).toBe(1);
  expect(posts[0].backend).toBe("codex");
  expect(posts[0].model_override).toBe("gpt-6-astra");
  expect(posts[0].model_effort).toBe("high");
  expect(posts[0].cyber_access).toBe("standard");
});

test("composer effort: absent for a harness the core ignores effort for, and reset on switch", async ({ page }) => {
  const { posts } = await setup(page);
  const picks = page.locator(".picks .model:not(.cyber-pill)");

  await picks.nth(2).click();
  await page.locator(".picker").getByRole("option", { name: /Max/ }).first().click();
  await expect(picks.nth(2)).toHaveText(/Max/);

  // Codex → OpenCode: the core forces model_effort to null there, so the
  // control disappears rather than offering a level that would be dropped.
  await picks.nth(0).click();
  await page.locator(".picker").getByRole("option", { name: /^OpenCode/ }).click();
  await expect(page.locator(".picks .model:not(.cyber-pill)")).toHaveText(["OpenCode", "Smart (Default)"]);

  // Returning to Codex does not resurrect the dropped level.
  await page.locator(".picks .model:not(.cyber-pill)").nth(0).click();
  await page.locator(".picker").getByRole("option", { name: /^Codex/ }).click();
  await expect(page.locator(".picks .model:not(.cyber-pill)").nth(2)).toHaveText(/Default/);

  // ...and a launch on the effort-less harness omits the field entirely.
  await page.locator(".picks .model:not(.cyber-pill)").nth(0).click();
  await page.locator(".picker").getByRole("option", { name: /^OpenCode/ }).click();
  await page.getByPlaceholder("Describe a task, / for commands, @ for context").fill("ship it");
  await page.keyboard.press("Enter");
  await expect.poll(() => posts.length).toBe(1);
  expect(posts[0].backend).toBe("opencode");
  expect(posts[0]).not.toHaveProperty("model_effort");
});

// ---------------------------------------------------------------- feature 5

test("right-click a project: Project settings opens a page in the main panel", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: "Test", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Project settings" }).click();

  // A page, not a dialog — same navigation a cron uses.
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator(".tb-title")).toHaveText("Test · Settings");
  await expect(page.getByRole("heading", { name: "Test" })).toBeVisible();

  const cap = page.getByLabel("Maximum unfinished agents for this project");
  await expect(cap).toHaveValue("2");
  await expect(page.locator(".ps-usage")).toHaveText("1 / 2");
  // Plain language only: no storage or error identifiers on the page.
  await expect(page.locator(".ps-page")).not.toContainText("parallel_missions");
  await expect(page.locator(".ps-page")).not.toContainText("autonomy grant");
  // The autonomy grant is shown but not editable here.
  await expect(page.locator(".ps-readonly")).toContainText(["Reversible actions", "owner"]);
  await expect(page.locator(".ps-readonly input, .ps-readonly button")).toHaveCount(0);

  await page.screenshot({ path: "artifacts/orb-project-settings.png" });
});

test("a project cap refusal explains itself and links to that project's settings", async ({ page }) => {
  const { posts } = await setup(page, { capAt: { active: 2, cap: 2 } });
  await page.getByRole("button", { name: "Choose project" }).click();
  await page.getByRole("option", { name: "Test", exact: true }).click();
  const composer = page.getByPlaceholder("Describe a task, / for commands, @ for context");
  await composer.fill("start the SRv3 report");
  await page.keyboard.press("Enter");

  const alert = page.getByRole("alert");
  await expect(alert).toBeVisible();
  // The raw JSON body — and every storage identifier in it — must never reach
  // the user.
  await expect(alert).not.toContainText("parallel_missions_cap");
  await expect(alert).not.toContainText("parallel_missions");
  await expect(alert).not.toContainText('{"active"');
  await expect(alert).toContainText("limit of 2 unfinished agents (2 in use)");
  await expect(alert).toContainText("increase the limit in Project settings");
  // The refusal proves nothing about the provider, so it must not vouch for it.
  await expect(alert).not.toContainText(/nothing is wrong/i);
  await expect(page.locator(".launch-refusal-meta")).toHaveText("2 of 2 unfinished");

  // The draft survives, and nothing was retried on its own.
  await expect(composer).toHaveValue("start the SRv3 report");
  expect(posts.length).toBe(1);
  await page.screenshot({ path: "artifacts/orb-cap-refusal.png" });

  await page.getByRole("button", { name: "Open project settings" }).click();
  await expect(page.locator(".tb-title")).toHaveText("Test · Settings");
  await expect(page.getByLabel("Maximum unfinished agents for this project")).toBeVisible();
});

test("retrying a refused launch reuses the idempotency key, so no second mission is created", async ({ page }) => {
  const { posts } = await setup(page, { capAt: { active: 2, cap: 2 } });
  await page.getByRole("button", { name: "Choose project" }).click();
  await page.getByRole("option", { name: "Test", exact: true }).click();
  const composer = page.getByPlaceholder("Describe a task, / for commands, @ for context");
  await composer.fill("start the SRv3 report");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("alert")).toBeVisible();

  await composer.click();
  await page.keyboard.press("Enter");
  await expect.poll(() => posts.length).toBe(2);
  expect(posts[1].idempotency_key).toBe(posts[0].idempotency_key);
});

test("Concurrency limits expand inside client settings and preserve the draft", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: /Settings/ }).click();
  const summary = page.locator(".execution-disclosure > summary");
  await summary.click();
  const global = page.getByLabel("Maximum agents across all projects");
  await expect(global).toHaveValue("4");
  await expect(page.getByText("Total agents running across the backend. Each project can set a lower limit in its own settings.")).toBeVisible();
  await global.fill("7");
  await summary.click();
  await expect(global).not.toBeVisible();
  await summary.click();
  await expect(global).toHaveValue("7");
  await expect(page.locator(".settings-body h2")).toHaveText("Client");
  await page.screenshot({ path: "artifacts/orb-execution-settings.png" });
});


test("folder rename changes the real path, carries its agents, and supports cancellation", async ({ page }) => {
  await setup(page);
  const folders = new Set(["reference", "archive"]);
  const transfers: any[] = [], moved: any[] = [];
  let tags = ["orb-folder:reference"];
  const filed = () => ({ ...missions[0], project: "test", tags });
  await page.route(/\/api\/control\/missions/, async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.pathname.endsWith("/project")) { const body = request.postDataJSON(); moved.push(body); tags = body.tags; return route.fulfill({ json: {} }); }
    if (url.pathname.endsWith(MISSION_ID)) return route.fulfill({ json: filed() });
    if (url.pathname === "/api/control/missions" && request.method() === "GET") return route.fulfill({ json: url.searchParams.get("project") === "test" ? [filed(), missions[1]] : [] });
    await route.fallback();
  });
  await page.route("**/api/projects/test/**", async route => {
    const url = new URL(route.request().url()), path = url.searchParams.get("path") ?? "";
    if (url.pathname.endsWith("/files")) return route.fulfill({ json: { entries: [...folders].filter(key => (key.includes("/") ? key.slice(0, key.lastIndexOf("/")) : "") === path).map(key => ({ name: key.split("/").at(-1), kind: "dir" })) } });
    if (url.pathname.endsWith("/file/transfer")) {
      const body = route.request().postDataJSON(); transfers.push(body);
      folders.delete(body.path); folders.add(body.destination);
      return route.fulfill({ json: { path: body.destination } });
    }
    await route.fallback();
  });
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await page.getByRole("button", { name: "Folder actions for reference" }).click();
  await expect(page.getByRole("menu").getByRole("menuitem")).toContainText(["Rename", "Move…", "Cut", "Copy", "Delete…"]);
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click();
  await expect(page.getByLabel("Folder name", { exact: true })).toHaveValue("reference");
  await page.getByLabel("Folder name", { exact: true }).fill("Discard this");
  await page.keyboard.press("Escape");
  await page.getByRole("button", {name:"Discard changes"}).click();
  expect(transfers).toEqual([]);
  await page.locator(".row.folder", { hasText: "reference" }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click();
  await page.getByLabel("Folder name", { exact: true }).fill("Research");
  await page.getByRole("button", { name: "Rename", exact: true }).click();
  await expect(page.getByRole("button", { name: "Folder actions for Research" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Folder actions for reference" })).toHaveCount(0);
  expect(transfers).toEqual([{ path: "reference", destination: "Research", copy: false }]);
  await expect.poll(() => moved).toEqual([{ project: "test", tags: ["orb-folder:Research"] }]);
  await page.locator(".row.folder", { hasText: "Research" }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move…", exact: true }).click();
  await page.getByLabel("Destination folder", { exact: true }).fill("archive");
  await page.getByRole("button", { name: "Move", exact: true }).click();
  await expect.poll(() => transfers.at(-1)).toEqual({ path: "Research", destination: "archive/Research", copy: false });
  await expect.poll(() => moved.at(-1)).toEqual({ project: "test", tags: ["orb-folder:archive/Research"] });
});

test("file actions rename, cut/paste, copy/paste, move and delete actual paths", async ({ page }) => {
  await setup(page);
  await page.evaluate(() => {
    let text = '';
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
      writeText: async (value: string) => { text = value; }, readText: async () => text,
    } });
  });
  const files = new Map([['context.md', 'Important content']]);
  const transfers: any[] = [];
  await page.route('**/api/projects/test/**', async route => {
    const url = new URL(route.request().url()), path = url.searchParams.get('path') ?? '';
    if (url.pathname.endsWith('/files')) {
      const entries = [...files.keys()].filter(key => (key.includes('/') ? key.slice(0, key.lastIndexOf('/')) : '') === path)
        .map(key => ({name:key.split('/').at(-1),kind:'file'}));
      if (!path) entries.push({name:'archive',kind:'dir'});
      return route.fulfill({json:{entries}});
    }
    if (url.pathname.endsWith('/file/transfer')) {
      const body = route.request().postDataJSON(); transfers.push(body);
      if (files.has(body.destination)) return route.fulfill({status:400,body:'Destination already exists'});
      files.set(body.destination, files.get(body.path)!);
      if (!body.copy) files.delete(body.path);
      return route.fulfill({json:{path:body.destination}});
    }
    if (url.pathname.endsWith('/file')) {
      if (route.request().method() === 'DELETE') { files.delete(path); return route.fulfill({json:{}}); }
      return route.fulfill({json:{content:files.get(path) ?? ''}});
    }
    await route.fallback();
  });
  await expandProject(page);
  const file = (name: string) => page.locator('.row.file').filter({hasText:name});
  await file('context.md').click({button:'right'});
  await page.getByRole('menuitem',{name:'Rename',exact:true}).click();
  await page.getByLabel('File name',{exact:true}).fill('renamed.md');
  await page.getByRole('button',{name:'Rename',exact:true}).click();
  await expect.poll(() => transfers).toEqual([{path:'context.md',destination:'renamed.md',copy:false}]);
  await expect(file('renamed.md')).toBeVisible();
  const shortcut = process.platform === 'darwin' ? 'Meta' : 'Control';
  await file('renamed.md').focus(); await page.keyboard.press(`${shortcut}+x`);
  const archive = page.locator('.row.folder .row-main').filter({hasText:'archive'});
  await archive.focus(); await page.keyboard.press(`${shortcut}+v`);
  await expect.poll(() => files.has('archive/renamed.md')).toBe(true);
  await expect(file('renamed.md')).toBeVisible();
  await expect(page.locator('[data-tree-id="pf:test:archive/renamed.md"]')).toBeVisible();
  await file('renamed.md').focus(); await page.keyboard.press(`${shortcut}+c`);
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toContain('"copy":true');
  await page.getByRole('button',{name:'Test',exact:true}).focus(); await page.keyboard.press(`${shortcut}+v`);
  await expect.poll(() => files.has('renamed.md')).toBe(true);
  expect(files.get('renamed.md')).toBe('Important content');
  expect(files.get('archive/renamed.md')).toBe('Important content');
  await page.locator('[data-tree-id="pf:test:renamed.md"] .row.file').click({button:'right'});
  await page.getByRole('menuitem',{name:'Move…',exact:true}).click();
  await page.getByLabel('Destination folder',{exact:true}).fill('archive');
  await page.getByRole('button',{name:'Move',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('already exists');
  await page.keyboard.press('Escape');
  await page.getByRole('button', {name:'Discard changes'}).click();
  await page.locator('[data-tree-id="pf:test:renamed.md"] .row.file').click({button:'right'});
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  await page.getByRole('button',{name:'Delete',exact:true}).click();
  await expect.poll(() => files.has('renamed.md')).toBe(false);
  expect(files.has('archive/renamed.md')).toBe(true);
  await page.locator('[data-tree-id="pf:test:archive/renamed.md"] .row.file').click({button:'right'});
  await page.getByRole('menuitem',{name:'Move…',exact:true}).click();
  await page.getByLabel('Destination folder',{exact:true}).fill('');
  await page.getByRole('button',{name:'Move',exact:true}).click();
  await expect.poll(() => files.has('archive/renamed.md')).toBe(false);
  expect(files.get('renamed.md')).toBe('Important content');
  expect(transfers[0]).toEqual({path:'context.md',destination:'renamed.md',copy:false});
});

test('folder deletion requires confirmation and agent badges overlap their icon', async ({page}) => {
  await setup(page);
  let deleted = false;
  await page.route('**/api/projects/test/files?*', route => route.fulfill({json:{entries:deleted ? [] : [{name:'reference',kind:'dir'}]}}));
  await page.route('**/api/projects/test/file?*', async route => {
    if(route.request().method() !== 'DELETE') return route.fallback();
    expect(new URL(route.request().url()).searchParams.get('path')).toBe('reference');
    deleted=true; await route.fulfill({json:{}});
  });
  await expandProject(page);
  const glyph=page.locator('.mission-glyph').first();
  const identity=await glyph.boundingBox(), badge=await glyph.locator('.mission-status-mark').boundingBox();
  expect(identity!.width).toBeLessThanOrEqual(18);
  expect(badge!.x).toBeLessThan(identity!.x+identity!.width);
  expect(badge!.y).toBeLessThan(identity!.y+identity!.height);
  const folder=page.locator('.row.folder').filter({hasText:'reference'});
  await folder.click({button:'right'});
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  await expect(page.getByRole('dialog')).toContainText('all files and subfolders');
  await page.getByRole('button',{name:'Cancel',exact:true}).click();
  expect(deleted).toBe(false);
  await page.getByRole('button',{name:'Folder actions for reference'}).click();
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  await page.getByRole('button',{name:'Delete',exact:true}).click();
  await expect(folder).toHaveCount(0);
  expect(deleted).toBe(true);
});

test('a refused sidebar action explains itself in a dialog, not inside the project list', async ({page}) => {
  await setup(page);
  await page.evaluate(() => {
    let text = '';
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async (value: string) => { text = value; }, readText: async () => text } });
  });
  await page.route('**/api/projects/test/file/transfer', route => route.fulfill({status:400,body:'This folder contains files that are not part of the project context; move or delete them first'}));
  await expandProject(page);
  const shortcut = process.platform === 'darwin' ? 'Meta' : 'Control';
  await page.locator('.row.folder .row-main').filter({hasText:'reference'}).focus(); await page.keyboard.press(`${shortcut}+x`);
  await page.getByRole('button',{name:'Test',exact:true}).focus(); await page.keyboard.press(`${shortcut}+v`);
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByRole('alert')).toContainText('Choose a different name or folder');
  await expect(page.locator('.sidebar .error-notice, nav .error-notice')).toHaveCount(0);
  await dialog.locator('.dlg-foot').getByRole('button',{name:'Close',exact:true}).click();
  await expect(dialog).toHaveCount(0);
});
