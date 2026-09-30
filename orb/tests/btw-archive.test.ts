import { expect, test } from "vitest";
import { archiveParts } from "../src/btwContext";

test("a long conversation is archived in bounded parts without freezing the page", async () => {
  const rows = Array.from({ length: 4000 }, (_, i) => `[${i}] tool_result: ${"é".repeat(1500)}`);
  const written: Record<string, string> = {};
  const started = performance.now();
  const paths = await archiveParts("events.jsonl", rows, async (name, text) => { written[name] = text; return name; });
  expect(performance.now() - started).toBeLessThan(2000);
  expect(paths).toEqual(["events.jsonl.0", "events.jsonl.1"]);
  const encoder = new TextEncoder();
  for (const path of paths) expect(encoder.encode(written[path]).length).toBeLessThanOrEqual(8 * 1024 * 1024);
  expect(paths.map(p => written[p]).join("")).toBe(rows.map(r => r + "\n").join(""));
});

test("one oversized row is split on character boundaries", async () => {
  const written: Record<string, string> = {};
  const paths = await archiveParts("t", ["é".repeat(5 * 1024 * 1024)], async (name, text) => { written[name] = text; return name; });
  expect(paths).toEqual(["t.0", "t.1"]);
  expect(paths.map(p => written[p]).join("")).toBe("é".repeat(5 * 1024 * 1024) + "\n");
  expect(written["t.0"].endsWith("é")).toBe(true);
});
