import { expect, test } from "@playwright/test";
import { openConversation } from "./btwSideFixture";

// One vertical rhythm for the transcript: 22px above every turn after the first, whatever
// ended the turn before it (an answer, a tool group or an error card), and 12px between
// the blocks of a turn. Gaps are measured between what is drawn: an answer's box includes
// padding around its text, so its text is measured, not its box.

const TURN_GAP = 22;
const BLOCK_GAP = 12;

const ev = (seq: number, type: string, extra: Record<string, unknown>) =>
  ({ id: `e-${seq}`, event_id: `e-${seq}`, sequence: seq, event_type: type, timestamp: "2026-11-07T06:00:00Z", ...extra });
const tool = (seq: number, id: string, command: string) => [
  ev(seq, "tool_call", { tool_call_id: id, tool_name: "Bash", content: JSON.stringify({ command }) }),
  ev(seq + 1, "tool_result", { tool_call_id: id, content: "ok" }),
];
const events = [
  ev(1, "user_message", { content: "Build the ledger hub" }),
  ...tool(2, "t1", "lake build"),
  ev(4, "assistant_message", { content: "The build passed." }),
  // An answer ends the turn above this message.
  ev(5, "user_message", { content: "Now run the tests" }),
  ...tool(6, "t2", "lake test"),
  ev(8, "assistant_message", { content: "Tests ran." }),
  ev(9, "error", { content: "Provider returned 529 overloaded" }),
  // An error card ends the turn above this message.
  ev(10, "user_message", { content: "Continue." }),
  ...tool(11, "t3", "lake exe report"),
  ev(13, "error", { content: "Provider returned 529 overloaded again" }),
  ev(14, "user_message", { content: "Continue." }),
  ev(15, "assistant_message", { content: "Picking the report back up." }),
  // An answer with no tools before it, then a turn that ends on a tool group.
  ev(16, "user_message", { content: "Publish it" }),
  ...tool(17, "t4", "lake exe publish"),
  ev(19, "user_message", { content: "Stop there" }),
];

for (const theme of ["dark", "light"] as const) {
  test(`transcript blocks share one vertical rhythm: ${theme}`, async ({ page }) => {
    await page.setViewportSize({ width: 1200, height: 1500 });
    await openConversation(page, theme, events, "failed");
    await expect(page.getByText("Stop there")).toBeVisible({ timeout: 20_000 });
    await expect(page.locator("[data-turn-key] > .error-notice")).toHaveCount(2);

    const gaps = await page.evaluate(() => {
      type Drawn = { kind: string; turn: string; top: number; bottom: number };
      const drawn: Drawn[] = [];
      for (const turn of Array.from(document.querySelectorAll<HTMLElement>("[data-turn-key]"))) {
        for (const block of Array.from(turn.children) as HTMLElement[]) {
          if (block.getBoundingClientRect().height === 0) continue;
          const kind = block.className.trim().split(/\s+/)[0];
          // An answer is measured by its text, not by the padded box around it.
          const content = kind === "st-text" ? Array.from(block.querySelectorAll<HTMLElement>(".md > *")) : [block];
          const rects = content.map((el) => el.getBoundingClientRect()).filter((r) => r.height > 0);
          drawn.push({ kind, turn: turn.dataset.turnKey ?? "", top: Math.min(...rects.map((r) => r.top)), bottom: Math.max(...rects.map((r) => r.bottom)) });
        }
      }
      return drawn.slice(1).map((block, i) => ({
        pair: `${drawn[i].kind} → ${block.kind}`,
        newTurn: drawn[i].turn !== block.turn,
        gap: Math.round(block.top - drawn[i].bottom),
      }));
    });

    const between = gaps.filter((g) => g.newTurn);
    const within = gaps.filter((g) => !g.newTurn);
    // Every kind of turn ending is in the fixture.
    expect(between.map((g) => g.pair).sort()).toEqual(
      ["error-notice → user", "error-notice → user", "st-text → user", "st-text → user", "st-work → user"].sort());
    expect(within.map((g) => g.pair)).toEqual(expect.arrayContaining(
      ["user → st-work", "st-work → st-text", "st-text → error-notice", "st-work → error-notice", "user → st-text"]));
    expect(between.filter((g) => g.gap !== TURN_GAP)).toEqual([]);
    expect(within.filter((g) => g.gap !== BLOCK_GAP)).toEqual([]);
  });
}
