import { test, expect } from "@playwright/test";
import { eventPage } from "./eventPageFixture";

const MD_SAMPLE = [
  "# Editorial Typography Brief",
  "",
  "This paragraph checks `inline_token` inside editorial Markdown preview.",
  "",
  "> Quoted prose should also inherit the editorial serif face.",
  "",
  "```ts",
  "export const answer = 42;",
  "```",
  "",
].join("\n");

for (const theme of ["dark", "light"] as const) {
  test(`Files Editor Markdown preview uses editorial serif, source mode uses mono, and mission transcript stays sans (${theme})`, async ({
    page,
  }) => {
    await page.addInitScript((t) => {
      localStorage.setItem("orb.apiUrl", location.origin);
      localStorage.setItem("orb.jwt", "test");
      localStorage.setItem("orb-theme", t);
    }, theme);

    const mission = {
      id: "m-typo-1",
      title: "Typography Check Mission",
      status: "completed",
      history: [],
      workspace_name: "host",
      created_at: "",
      updated_at: "",
    };
    const missionEvents = [
      {
        id: 101,
        mission_id: mission.id,
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
        mission_id: mission.id,
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
        return route.fulfill({ json: [mission] });
      }
      if (path === `/api/control/missions/${mission.id}`) {
        return route.fulfill({ json: mission });
      }
      if (path === `/api/control/missions/${mission.id}/events`) {
        return route.fulfill(eventPage(route, missionEvents));
      }
      if (path.endsWith("/files")) {
        return route.fulfill({
          json: {
            entries: [
              { name: "notes.md", kind: "file" },
              { name: "design.markdown", kind: "file" },
            ],
          },
        });
      }
      if (path.endsWith("/file")) {
        return route.fulfill({ json: { content: MD_SAMPLE, revision: 1 } });
      }
      if (path.endsWith("/crons")) {
        return route.fulfill({ json: { jobs: [] } });
      }
      if (path.endsWith("/controller")) {
        return route.fulfill({ json: { job: null, runs: [] } });
      }
      return route.fulfill({ json: [] });
    });

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
      const rootCs = getComputedStyle(root);
      const pCs = getComputedStyle(p);
      return {
        rootFont: rootCs.fontFamily,
        rootMaxWidth: rootCs.maxWidth,
        pFont: pCs.fontFamily,
        pFontSize: parseFloat(pCs.fontSize),
        pLineHeight: parseFloat(pCs.lineHeight),
        h1Font: getComputedStyle(h1).fontFamily,
        quoteFont: getComputedStyle(quoteP).fontFamily,
        inlineCodeFont: getComputedStyle(inlineCode).fontFamily,
        fencedPreFont: getComputedStyle(fencedPre).fontFamily,
        fencedCodeFont: getComputedStyle(fencedCode).fontFamily,
      };
    });

    expect(previewStyles.rootFont).toContain("IBM Plex Serif");
    expect(previewStyles.pFont).toContain("IBM Plex Serif");
    expect(previewStyles.h1Font).toContain("IBM Plex Serif");
    expect(previewStyles.quoteFont).toContain("IBM Plex Serif");
    expect(previewStyles.rootMaxWidth).not.toBe("none");
    expect(previewStyles.pLineHeight / previewStyles.pFontSize).toBeGreaterThanOrEqual(
      1.6,
    );
    expect(previewStyles.inlineCodeFont).toContain("Lilex Nerd Font");
    expect(previewStyles.inlineCodeFont).toContain("IBM Plex Mono");
    expect(previewStyles.inlineCodeFont).not.toContain("IBM Plex Serif");
    expect(previewStyles.fencedPreFont).toContain("Lilex Nerd Font");
    expect(previewStyles.fencedCodeFont).toContain("Lilex Nerd Font");
    expect(previewStyles.fencedCodeFont).not.toContain("IBM Plex Serif");

    // 2. Toggle code/source mode via Cmd+/ (or Ctrl+/) -> switches cleanly to --mono
    await page.keyboard.press("Control+/");
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

    // Toggle back to preview via Meta+/
    await page.keyboard.press("Meta+/");
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

    // 3. Mission discussion transcript stays --sans (NOT serif)
    await page
      .getByRole("button", { name: /Typography Check Mission/ })
      .click();
    await expect(page.locator(".st-text .md p").first()).toBeVisible();

    const transcriptFonts = await page.evaluate(() => ({
      body: getComputedStyle(document.body).fontFamily,
      sidebar: getComputedStyle(document.querySelector(".sidebar")!).fontFamily,
      userBubble: getComputedStyle(document.querySelector(".user")!).fontFamily,
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
    expect(transcriptFonts.assistantProse).toContain("IBM Plex Sans");
    expect(transcriptFonts.assistantProse).not.toContain("IBM Plex Serif");
    expect(transcriptFonts.assistantHeading).toContain("IBM Plex Sans");
    expect(transcriptFonts.assistantHeading).not.toContain("IBM Plex Serif");
    expect(transcriptFonts.assistantInlineCode).toContain("Lilex Nerd Font");
    expect(transcriptFonts.assistantFencedCode).toContain("Lilex Nerd Font");
  });
}

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
          content: q.path.endsWith(".md")
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

  const panelPreview = await page.evaluate(() => ({
    chatProse: getComputedStyle(document.querySelector(".main .md p")!)
      .fontFamily,
    fileProse: getComputedStyle(
      document.querySelector(".file-preview .md.md-editorial p")!,
    ).fontFamily,
    fileInlineCode: getComputedStyle(
      document.querySelector(".file-preview .md.md-editorial p code")!,
    ).fontFamily,
    fileFencedPre: getComputedStyle(
      document.querySelector(".file-preview .md.md-editorial pre")!,
    ).fontFamily,
  }));

  expect(panelPreview.chatProse).toContain("IBM Plex Sans");
  expect(panelPreview.chatProse).not.toContain("IBM Plex Serif");
  expect(panelPreview.fileProse).toContain("IBM Plex Serif");
  expect(panelPreview.fileInlineCode).toContain("Lilex Nerd Font");
  expect(panelPreview.fileInlineCode).not.toContain("IBM Plex Serif");
  expect(panelPreview.fileFencedPre).toContain("Lilex Nerd Font");
  expect(panelPreview.fileFencedPre).not.toContain("IBM Plex Serif");

  // Focus file panel and toggle source mode via Meta+/
  await page.locator(".file-preview").click();
  await page.keyboard.press("Meta+/");
  await expect(page.locator(".file-source-code")).toBeVisible();
  await expect(page.locator(".file-preview .md.md-editorial")).toHaveCount(0);

  const panelSourceFont = await page
    .locator(".file-source-code")
    .evaluate((el) => getComputedStyle(el).fontFamily);
  expect(panelSourceFont).toContain("Lilex Nerd Font");
  expect(panelSourceFont).toContain("IBM Plex Mono");
  expect(panelSourceFont).not.toContain("IBM Plex Serif");

  // Toggle back to preview via Control+/
  await page.keyboard.press("Control+/");
  await expect(page.locator(".file-preview .md.md-editorial")).toBeVisible();
  const backToPreviewFont = await page
    .locator(".file-preview .md.md-editorial p")
    .first()
    .evaluate((el) => getComputedStyle(el).fontFamily);
  expect(backToPreviewFont).toContain("IBM Plex Serif");
});
