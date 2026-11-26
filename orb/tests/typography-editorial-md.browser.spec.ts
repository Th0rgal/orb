import { test, expect, type Page } from "@playwright/test";
import { eventPage } from "./eventPageFixture";

const MD_SAMPLE = [
  "# Editorial Typography Brief",
  "",
  "This paragraph checks `inline_token` inside editorial Markdown preview.",
  "",
  "> Quoted prose should also inherit the editorial serif face.",
  "",
  "| Metric | Value |",
  "| --- | ---: |",
  "| Measure | 68ch |",
  "| Line height | 1.7 |",
  "",
  "```ts",
  "export const answer = 42;",
  "```",
  "",
].join("\n");

const YAML_SAMPLE = "mode: editorial\nmeasure: 68ch\n";

const DEFAULT_MISSION = {
  id: "m-typo-1",
  title: "Typography Check Mission",
  status: "completed",
  history: [],
  workspace_name: "host",
  created_at: "",
  updated_at: "",
};

const DEFAULT_MISSION_EVENTS = [
  {
    id: 101,
    mission_id: DEFAULT_MISSION.id,
    sequence: 1,
    event_type: "user_message",
    timestamp: "2026-11-24T16:00:00Z",
    tool_call_id: null,
    tool_name: null,
    content: "Check transcript typography.",
    metadata: {},
  },
  {
    id: 102,
    mission_id: DEFAULT_MISSION.id,
    sequence: 2,
    event_type: "assistant_message",
    timestamp: "2026-11-24T16:00:02Z",
    tool_call_id: null,
    tool_name: null,
    content:
      "## Transcript Summary\n\nAgent discussion prose stays sans while `src/styles.css` stays monospace.\n\n```ts\nconst ok = true;\n```",
    metadata: { success: true },
  },
];

async function mockProjectApi(page: Page) {
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (path === "/api/control/stream") {
      return route.fulfill({ contentType: "text/event-stream", body: "" });
    }
    if (path === "/api/projects") {
      return route.fulfill({
        json: { projects: [{ slug: "test", title: "Test" }] },
      });
    }
    if (
      path === "/api/control/missions" &&
      url.searchParams.get("project") === "test"
    ) {
      return route.fulfill({ json: [DEFAULT_MISSION] });
    }
    if (path === `/api/control/missions/${DEFAULT_MISSION.id}`) {
      return route.fulfill({ json: DEFAULT_MISSION });
    }
    if (path === `/api/control/missions/${DEFAULT_MISSION.id}/events`) {
      return route.fulfill(eventPage(route, DEFAULT_MISSION_EVENTS));
    }
    if (path.endsWith("/files")) {
      return route.fulfill({
        json: {
          entries: [
            { name: "notes.md", kind: "file" },
            { name: "design.markdown", kind: "file" },
            { name: "guide.mdx", kind: "file" },
            { name: "config.yaml", kind: "file" },
          ],
        },
      });
    }
    if (path.endsWith("/file")) {
      const filePath = url.searchParams.get("path") ?? "";
      return route.fulfill({
        json: {
          content: filePath.endsWith(".yaml") ? YAML_SAMPLE : MD_SAMPLE,
          revision: 1,
        },
      });
    }
    if (path.endsWith("/crons")) {
      return route.fulfill({ json: { jobs: [] } });
    }
    if (path.endsWith("/controller")) {
      return route.fulfill({ json: { job: null, runs: [] } });
    }
    return route.fulfill({ json: [] });
  });
}

for (const theme of ["dark", "light"] as const) {
  test(`Files Editor Markdown preview uses editorial serif, source mode uses mono, and mission transcript stays sans (${theme})`, async ({
    page,
  }) => {
    await page.addInitScript((t) => {
      localStorage.setItem("orb.apiUrl", location.origin);
      localStorage.setItem("orb.jwt", "test");
      localStorage.setItem("orb-theme", t);
    }, theme);

    await mockProjectApi(page);
    await page.goto("/");

    // 1. Open `.md` in Project Files Editor -> preview mode uses --serif-editorial
    await page.getByRole("button", { name: "Test", exact: true }).click();
    await page.getByRole("button", { name: "notes.md" }).click();
    await expect(page.locator(".pf-path")).toHaveText("test/notes.md");

    const previewRoot = page.locator(".md.md-editorial");
    await expect(previewRoot).toBeVisible();

    const previewStyles = await previewRoot.evaluate((root) => {
      const p = root.querySelector("p")!;
      const h1 = root.querySelector("h1")!;
      const quoteP = root.querySelector("blockquote p")!;
      const inlineCode = root.querySelector("p code")!;
      const fencedPre = root.querySelector("pre")!;
      const fencedCode = root.querySelector("pre code")!;
      const table = root.querySelector("table")!;
      const tableCell = root.querySelector("td")!;
      const rootCs = getComputedStyle(root);
      const pCs = getComputedStyle(p);
      const preCs = getComputedStyle(fencedPre);
      const tableCs = getComputedStyle(table);
      return {
        rootFont: rootCs.fontFamily,
        rootMaxWidth: rootCs.maxWidth,
        pFont: pCs.fontFamily,
        pFontSize: parseFloat(pCs.fontSize),
        pLineHeight: parseFloat(pCs.lineHeight),
        h1Font: getComputedStyle(h1).fontFamily,
        quoteFont: getComputedStyle(quoteP).fontFamily,
        inlineCodeFont: getComputedStyle(inlineCode).fontFamily,
        fencedPreFont: preCs.fontFamily,
        fencedPreFontSize: parseFloat(preCs.fontSize),
        fencedPreLineHeight: parseFloat(preCs.lineHeight),
        fencedCodeFont: getComputedStyle(fencedCode).fontFamily,
        tableFont: tableCs.fontFamily,
        tableFontSize: parseFloat(tableCs.fontSize),
        tableLineHeight: parseFloat(tableCs.lineHeight),
        tableCellFont: getComputedStyle(tableCell).fontFamily,
      };
    });

    expect(previewStyles.rootFont).toContain("IBM Plex Serif");
    expect(previewStyles.pFont).toContain("IBM Plex Serif");
    expect(previewStyles.h1Font).toContain("IBM Plex Serif");
    expect(previewStyles.quoteFont).toContain("IBM Plex Serif");
    const rootMaxWidthPx = parseFloat(previewStyles.rootMaxWidth);
    expect(Number.isFinite(rootMaxWidthPx)).toBe(true);
    expect(rootMaxWidthPx).toBeGreaterThanOrEqual(400);
    expect(rootMaxWidthPx).toBeLessThanOrEqual(800);
    expect(
      previewStyles.pLineHeight / previewStyles.pFontSize,
    ).toBeGreaterThanOrEqual(1.6);
    expect(previewStyles.inlineCodeFont).toContain("Lilex Nerd Font");
    expect(previewStyles.inlineCodeFont).toContain("IBM Plex Mono");
    expect(previewStyles.inlineCodeFont).not.toContain("IBM Plex Serif");
    expect(previewStyles.fencedPreFont).toContain("Lilex Nerd Font");
    expect(previewStyles.fencedPreFontSize).toBeCloseTo(13, 1);
    expect(previewStyles.fencedPreLineHeight).toBeLessThanOrEqual(22);
    expect(previewStyles.fencedCodeFont).toContain("Lilex Nerd Font");
    expect(previewStyles.fencedCodeFont).not.toContain("IBM Plex Serif");
    expect(previewStyles.tableFont).toContain("IBM Plex Sans");
    expect(previewStyles.tableFont).not.toContain("IBM Plex Serif");
    expect(previewStyles.tableCellFont).toContain("IBM Plex Sans");
    expect(
      previewStyles.tableLineHeight / previewStyles.tableFontSize,
    ).toBeLessThanOrEqual(1.6);

    // 2. Toggle code/source mode via primary modifier + / -> switches cleanly to --mono
    await page.keyboard.press("ControlOrMeta+/");
    await expect(page.locator(".md-ta")).toBeVisible();
    await expect(page.locator(".md.md-editorial")).toHaveCount(0);

    const sourceFonts = await page.evaluate(() => ({
      ta: getComputedStyle(document.querySelector(".md-ta")!).fontFamily,
      hl: getComputedStyle(document.querySelector(".md-hl")!).fontFamily,
    }));
    expect(sourceFonts.ta).toContain("Lilex Nerd Font");
    expect(sourceFonts.ta).toContain("IBM Plex Mono");
    expect(sourceFonts.ta).not.toContain("IBM Plex Serif");
    expect(sourceFonts.hl).toContain("Lilex Nerd Font");
    expect(sourceFonts.hl).not.toContain("IBM Plex Serif");

    // Toggle back to preview via primary modifier + /
    await page.keyboard.press("ControlOrMeta+/");
    await expect(page.locator(".md.md-editorial")).toBeVisible();
    await expect(page.locator(".md-ta")).toHaveCount(0);

    // Also verify `.markdown` extension uses editorial serif preview
    await page.getByRole("button", { name: "design.markdown" }).click();
    await expect(page.locator(".pf-path")).toHaveText("test/design.markdown");
    await expect(page.locator(".md.md-editorial p").first()).toBeVisible();
    const markdownExtFont = await page
      .locator(".md.md-editorial p")
      .first()
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(markdownExtFont).toContain("IBM Plex Serif");

    // Verify `.mdx` extension previews in editorial serif and toggles cleanly to mono
    await page.getByRole("button", { name: "guide.mdx" }).click();
    await expect(page.locator(".pf-path")).toHaveText("test/guide.mdx");
    await expect(page.locator(".md.md-editorial p").first()).toBeVisible();
    await expect(
      page.locator(".pf-bar").getByRole("button", { name: "Edit" }),
    ).toBeVisible();
    const mdxPreviewFont = await page
      .locator(".md.md-editorial p")
      .first()
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(mdxPreviewFont).toContain("IBM Plex Serif");

    await page.keyboard.press("ControlOrMeta+/");
    await expect(page.locator(".md-ta")).toBeVisible();
    const mdxSourceFont = await page
      .locator(".md-ta")
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(mdxSourceFont).toContain("Lilex Nerd Font");
    expect(mdxSourceFont).not.toContain("IBM Plex Serif");
    await page.keyboard.press("ControlOrMeta+/");
    await expect(page.locator(".md.md-editorial")).toBeVisible();

    // Verify non-Markdown file opens in source mode without a no-op Edit/Preview toggle
    await page.getByRole("button", { name: "config.yaml" }).click();
    await expect(page.locator(".pf-path")).toHaveText("test/config.yaml");
    await expect(page.locator(".md-ta")).toBeVisible();
    await expect(page.locator(".md.md-editorial")).toHaveCount(0);
    await expect(
      page.locator(".pf-bar").getByRole("button", { name: /^(Edit|Preview)$/ }),
    ).toHaveCount(0);

    // 3. Mission discussion transcript and composer stay --sans (NOT serif)
    await page
      .getByRole("button", { name: /Typography Check Mission/ })
      .click();
    await expect(page.locator(".st-text .md p").first()).toBeVisible();
    await expect(page.locator(".composer textarea")).toBeVisible();

    const transcriptFonts = await page.evaluate(() => ({
      body: getComputedStyle(document.body).fontFamily,
      sidebar: getComputedStyle(document.querySelector(".sidebar")!).fontFamily,
      userBubble: getComputedStyle(document.querySelector(".user")!).fontFamily,
      composerTextarea: getComputedStyle(
        document.querySelector(".composer textarea")!,
      ).fontFamily,
      assistantProse: getComputedStyle(
        document.querySelector(".st-text .md p")!,
      ).fontFamily,
      assistantHeading: getComputedStyle(
        document.querySelector(".st-text .md h2")!,
      ).fontFamily,
      assistantInlineCode: getComputedStyle(
        document.querySelector(".st-text .md p code")!,
      ).fontFamily,
      assistantFencedCode: getComputedStyle(
        document.querySelector(".st-text .md pre code")!,
      ).fontFamily,
      hasEditorialClassInTranscript: !!document.querySelector(
        ".st-text .md-editorial",
      ),
    }));

    expect(transcriptFonts.hasEditorialClassInTranscript).toBe(false);
    expect(transcriptFonts.body).toContain("IBM Plex Sans");
    expect(transcriptFonts.sidebar).toContain("IBM Plex Sans");
    expect(transcriptFonts.userBubble).toContain("IBM Plex Sans");
    expect(transcriptFonts.composerTextarea).toContain("IBM Plex Sans");
    expect(transcriptFonts.composerTextarea).not.toContain("IBM Plex Serif");
    expect(transcriptFonts.assistantProse).toContain("IBM Plex Sans");
    expect(transcriptFonts.assistantProse).not.toContain("IBM Plex Serif");
    expect(transcriptFonts.assistantHeading).toContain("IBM Plex Sans");
    expect(transcriptFonts.assistantHeading).not.toContain("IBM Plex Serif");
    expect(transcriptFonts.assistantInlineCode).toContain("Lilex Nerd Font");
    expect(transcriptFonts.assistantFencedCode).toContain("Lilex Nerd Font");

    // If the /btw side question panel is available on this mission, verify it stays sans too.
    const btwBtn = page.getByRole("button", { name: "Side question" });
    if (await btwBtn.isVisible()) {
      await btwBtn.click();
      const btwTextarea = page.locator(".btw-panel textarea");
      await expect(btwTextarea).toBeVisible();
      const btwFont = await btwTextarea.evaluate(
        (el) => getComputedStyle(el).fontFamily,
      );
      expect(btwFont).toContain("IBM Plex Sans");
      expect(btwFont).not.toContain("IBM Plex Serif");
    }
  });
}

test("macOS platform branch accepts Meta+/ and rejects Control+/", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    Object.defineProperty(navigator, "userAgentData", {
      value: undefined,
      configurable: true,
    });
    Object.defineProperty(navigator, "platform", {
      value: "MacIntel",
      configurable: true,
    });
  });

  await mockProjectApi(page);
  await page.goto("/");
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await page.getByRole("button", { name: "notes.md" }).click();
  await expect(page.locator(".md.md-editorial")).toBeVisible();

  // On macOS, Control+/ must NOT toggle source mode.
  await page.keyboard.press("Control+/");
  await expect(page.locator(".md.md-editorial")).toBeVisible();
  await expect(page.locator(".md-ta")).toHaveCount(0);

  // Meta+/ toggles to source and back to preview.
  await page.keyboard.press("Meta+/");
  await expect(page.locator(".md-ta")).toBeVisible();
  await expect(page.locator(".md.md-editorial")).toHaveCount(0);

  await page.keyboard.press("Meta+/");
  await expect(page.locator(".md.md-editorial")).toBeVisible();
  await expect(page.locator(".md-ta")).toHaveCount(0);
});

test("Linux platform branch accepts Control+/ to toggle source mode", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    Object.defineProperty(navigator, "userAgentData", {
      value: undefined,
      configurable: true,
    });
    Object.defineProperty(navigator, "platform", {
      value: "Linux x86_64",
      configurable: true,
    });
  });

  await mockProjectApi(page);
  await page.goto("/");
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await page.getByRole("button", { name: "notes.md" }).click();
  await expect(page.locator(".md.md-editorial")).toBeVisible();

  await page.keyboard.press("Control+/");
  await expect(page.locator(".md-ta")).toBeVisible();
  await expect(page.locator(".md.md-editorial")).toHaveCount(0);

  await page.keyboard.press("Control+/");
  await expect(page.locator(".md.md-editorial")).toBeVisible();
  await expect(page.locator(".md-ta")).toHaveCount(0);
});

test("SkillPage renders editorial serif preview and toggles raw source via ControlOrMeta+/", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });

  const skillContent = [
    "---",
    "name: agent-browser",
    "description: Drive a real browser.",
    "---",
    "",
    "# Agent browser",
    "",
    "Open a page and inspect its typography.",
    "",
    "```bash",
    "agent-browser open https://example.com",
    "```",
    "",
  ].join("\n");

  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/control/stream") {
      return route.fulfill({ contentType: "text/event-stream", body: "" });
    }
    if (path === "/api/library/skill") {
      return route.fulfill({
        json: [
          {
            name: "agent-browser",
            description: "Drive a real browser.",
            path: "skill/agent-browser",
          },
        ],
      });
    }
    if (path === "/api/library/skill/agent-browser") {
      return route.fulfill({
        json: {
          name: "agent-browser",
          path: "skill/agent-browser",
          content: skillContent,
          files: [],
          references: [],
        },
      });
    }
    if (path === "/api/library/status") {
      return route.fulfill({
        json: {
          remote: "git@github.com:Th0rgal/sandboxed-library.git",
          branch: "main",
          clean: true,
          ahead: 0,
          behind: 0,
          modified_files: [],
          last_synced_at: Math.floor(Date.now() / 1000) - 60,
        },
      });
    }
    if (path === "/api/projects") return route.fulfill({ json: { projects: [] } });
    return route.fulfill({ json: [] });
  });

  await page.goto("/");
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator('[data-settings-section="agents"]').click();
  await page.locator('[data-skill="agent-browser"] .skills-item-head').click();

  await expect(page.locator(".skill-main .md.md-editorial")).toBeVisible();
  const skillPreview = await page
    .locator(".skill-main .md.md-editorial")
    .evaluate((root) => ({
      pFont: getComputedStyle(root.querySelector("p")!).fontFamily,
      preLineHeight: parseFloat(getComputedStyle(root.querySelector("pre")!).lineHeight),
    }));
  expect(skillPreview.pFont).toContain("IBM Plex Serif");
  expect(skillPreview.preLineHeight).toBeLessThanOrEqual(22);

  // ControlOrMeta+/ toggles to raw source (showing YAML frontmatter) in monospace.
  await page.keyboard.press("ControlOrMeta+/");
  const ta = page.locator(".skill-main .md-ta");
  await expect(ta).toBeVisible();
  await expect(ta).toHaveValue(skillContent);
  const taFont = await ta.evaluate((el) => getComputedStyle(el).fontFamily);
  expect(taFont).toContain("Lilex Nerd Font");
  expect(taFont).not.toContain("IBM Plex Serif");

  // ControlOrMeta+/ toggles back to editorial preview.
  await page.keyboard.press("ControlOrMeta+/");
  await expect(page.locator(".skill-main .md.md-editorial")).toBeVisible();
  await expect(ta).toHaveCount(0);
});

test("Side FilePanel Markdown preview uses editorial serif while Cmd+/ source mode uses mono and adjacent chat stays sans", async ({
  page,
}) => {
  const entries = [
    { name: "guarantees.yaml", path: "audit/guarantees.yaml", kind: "file" },
    {
      name: "IMPLEMENTATION-BRIEF.md",
      path: "audit/IMPLEMENTATION-BRIEF.md",
      kind: "file",
    },
    {
      name: "NOTES.mdx",
      path: "audit/NOTES.mdx",
      kind: "file",
    },
  ];
  await page.route("**/api/**", (route) => {
    if (!route.request().url().endsWith("/file-resources")) {
      return route.fulfill({ json: { settings: {} } });
    }
    const q = route.request().postDataJSON();
    if (q.action === "roots") {
      return route.fulfill({
        json: {
          sources: [
            { id: "workspace", label: "Workspace · Core", available: true },
          ],
        },
      });
    }
    if (q.action === "list") {
      return route.fulfill({
        json: {
          entries: q.path
            ? entries
            : [{ name: "audit", path: "audit", kind: "dir" }],
        },
      });
    }
    if (q.action === "resolve") {
      return route.fulfill({
        json: {
          results: q.paths.map((reference: string) => ({
            reference,
            matches: entries.filter((e) => e.path === reference),
          })),
        },
      });
    }
    if (q.action === "read") {
      return route.fulfill({
        json: {
          content: /\.(mdx?|markdown)$/i.test(q.path)
            ? MD_SAMPLE
            : "guarantees:\n  - id: PRICE-1\n",
          size: 160,
          binary: false,
          truncated: false,
        },
      });
    }
    return route.fulfill({ json: {} });
  });

  await page.setViewportSize({ width: 1500, height: 900 });
  await page.goto("/tests/file-panel.html");
  await page
    .getByRole("button", { name: "IMPLEMENTATION-BRIEF.md", exact: true })
    .click();

  await expect(page.locator(".file-preview .md.md-editorial")).toBeVisible();

  const panelPreview = await page.evaluate(() => {
    const editorial = document.querySelector(".file-preview .md.md-editorial")!;
    const pre = editorial.querySelector("pre")!;
    const table = editorial.querySelector("table")!;
    const provenance = document.querySelector(".file-preview .file-provenance")!;
    return {
      chatProse: getComputedStyle(document.querySelector(".main .md p")!)
        .fontFamily,
      fileProse: getComputedStyle(editorial.querySelector("p")!).fontFamily,
      fileInlineCode: getComputedStyle(editorial.querySelector("p code")!)
        .fontFamily,
      fileFencedPre: getComputedStyle(pre).fontFamily,
      fileFencedPreLineHeight: parseFloat(getComputedStyle(pre).lineHeight),
      fileTableFont: getComputedStyle(table).fontFamily,
      editorialMaxWidth: parseFloat(getComputedStyle(editorial).maxWidth),
      provenanceMaxWidth: parseFloat(getComputedStyle(provenance).maxWidth),
    };
  });

  expect(panelPreview.chatProse).toContain("IBM Plex Sans");
  expect(panelPreview.chatProse).not.toContain("IBM Plex Serif");
  expect(panelPreview.fileProse).toContain("IBM Plex Serif");
  expect(panelPreview.fileInlineCode).toContain("Lilex Nerd Font");
  expect(panelPreview.fileInlineCode).not.toContain("IBM Plex Serif");
  expect(panelPreview.fileFencedPre).toContain("Lilex Nerd Font");
  expect(panelPreview.fileFencedPre).not.toContain("IBM Plex Serif");
  expect(panelPreview.fileFencedPreLineHeight).toBeLessThanOrEqual(22);
  expect(panelPreview.fileTableFont).toContain("IBM Plex Sans");
  expect(panelPreview.fileTableFont).not.toContain("IBM Plex Serif");
  expect(panelPreview.editorialMaxWidth).toBeGreaterThanOrEqual(400);
  expect(panelPreview.editorialMaxWidth).toBeLessThanOrEqual(760);
  expect(Number.isFinite(panelPreview.provenanceMaxWidth)).toBe(true);
  expect(panelPreview.provenanceMaxWidth).toBeGreaterThan(0);

  // Click a `.md` row in `.file-tree` and blur activeElement (simulating WKWebView
  // where clicking buttons does not focus them) to verify ControlOrMeta+/ toggles
  // immediately via rightPaneFocused without clicking inside `.file-preview`.
  const auditDir = page.getByRole("treeitem", { name: "audit" });
  if ((await auditDir.getAttribute("aria-expanded")) !== "true") {
    await auditDir.click();
  }
  await page.getByRole("treeitem", { name: "IMPLEMENTATION-BRIEF.md" }).click();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("ControlOrMeta+/");
  await expect(page.locator(".file-source-code")).toBeVisible();
  await expect(page.locator(".file-preview .md.md-editorial")).toHaveCount(0);

  const panelSourceFont = await page
    .locator(".file-source-code")
    .evaluate((el) => getComputedStyle(el).fontFamily);
  expect(panelSourceFont).toContain("Lilex Nerd Font");
  expect(panelSourceFont).toContain("IBM Plex Mono");
  expect(panelSourceFont).not.toContain("IBM Plex Serif");

  // Toggle back to preview via ControlOrMeta+/
  await page.keyboard.press("ControlOrMeta+/");
  await expect(page.locator(".file-preview .md.md-editorial")).toBeVisible();
  const backToPreviewFont = await page
    .locator(".file-preview .md.md-editorial p")
    .first()
    .evaluate((el) => getComputedStyle(el).fontFamily);
  expect(backToPreviewFont).toContain("IBM Plex Serif");

  // Also verify `.mdx` file in FilePanel renders editorial serif and toggles to mono.
  await page.getByRole("treeitem", { name: "NOTES.mdx" }).click();
  await expect(page.locator(".file-preview .md.md-editorial p").first()).toBeVisible();
  const mdxPanelFont = await page
    .locator(".file-preview .md.md-editorial p")
    .first()
    .evaluate((el) => getComputedStyle(el).fontFamily);
  expect(mdxPanelFont).toContain("IBM Plex Serif");

  await page.keyboard.press("ControlOrMeta+/");
  await expect(page.locator(".file-source-code")).toBeVisible();
  await page.keyboard.press("ControlOrMeta+/");
  await expect(page.locator(".file-preview .md.md-editorial")).toBeVisible();
});
