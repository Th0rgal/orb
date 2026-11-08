import { expect, test, vi } from "vitest";
import { clearConnection, connectionVersion, setConnection } from "../src/api";
import {
  applyLiveEventsToTranscriptCache,
  forgetPrefetchPauses,
  hydrateTranscriptFromDisk,
  loadTranscript,
  peekReadyTranscript,
  peekTranscript,
  putTranscript,
  refreshPresentationPreview,
  retainTranscript,
} from "../src/missionCache";
import { cacheReset } from "../src/pageCache";
import { savePersistedTranscript } from "../src/persistentCache";
import { historyScope } from "../src/resourceCache";
import {
  applyStreamEvent,
  applyStreamEvents,
  buildTranscript,
  clearTranscriptSessions,
  removeUsers,
  reuseUnchanged,
  transcriptSessionKey,
} from "../src/transcriptModel";

test("cloning or replacing StreamItem[] preserves session-keyed reducer dedup and tool state", () => {
  const session = transcriptSessionKey("mission-r6d", 1);
  const initial = buildTranscript(
    [
      { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "inspect repo" } },
      { type: "tool_call", eventId: "tc1", sequence: 2, data: { tool_call_id: "call-1", name: "bash", args: { command: "ls" } } },
    ],
    session,
  );
  const cloned = [...initial];
  expect(cloned).not.toBe(initial);

  const afterDup = applyStreamEvent(
    cloned,
    { type: "tool_call", eventId: "tc1", sequence: 2, data: { tool_call_id: "call-1", name: "bash", args: { command: "ls" } } },
    session,
  );
  expect(afterDup).toBe(cloned);

  const resolved = applyStreamEvent(
    cloned.slice(),
    { type: "tool_result", eventId: "tr1", sequence: 3, data: { tool_call_id: "call-1", name: "bash", result: "README.md" } },
    session,
  );
  const tools = resolved.filter(i => i.kind === "tool");
  expect(tools).toHaveLength(1);
  expect(tools[0]).toMatchObject({ kind: "tool", callId: "call-1", done: true, result: "README.md" });

  const withQueued = applyStreamEvent(
    resolved.slice(),
    { type: "user_message", eventId: "q1", data: { id: "q1", content: "queued follow-up", queued: true } },
    session,
  );
  const removed = removeUsers(withQueued.slice(), item => item.messageId === "q1", session);
  const reused = reuseUnchanged(resolved, removed, session);
  const withText = applyStreamEvent(
    reused.slice(),
    { type: "text_delta", sequence: 4, data: { content: "Done.", mode: "delta" } },
    session,
  );
  expect(withText.at(-1)).toMatchObject({ kind: "text", text: "Done." });
});

test("an event that changes nothing keeps the transcript's identity", () => {
  const items = buildTranscript([{ type: "user_message", data: { id: "u1", content: "hi" } }]);
  const same = applyStreamEvent(items, { type: "mission_activity", data: { label: "Tool running…" } });
  expect(same).toBe(items);
  const changed = applyStreamEvent(same, { type: "text_delta", data: { content: "hello", mode: "delta" } });
  expect(changed).not.toBe(items);
  expect(changed.length).toBe(2);
});

test("cross-tab queued user_message edit updates text in place while preserving key, order, and metadata", () => {
  const initial = buildTranscript([
    { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "first" } },
    { type: "user_message", eventId: "q1", data: { id: "q1", content: "draft one", queued: true, receipt: true, attached: true, source: "remote-queue" } },
    { type: "user_message", eventId: "q2", data: { id: "q2", content: "draft two", queued: true, receipt: true } },
  ]);
  const edited = applyStreamEvent(initial, {
    type: "user_message",
    eventId: "q1",
    data: { id: "q1", content: "edited in tab A", queued: true, source: "remote-queue" },
  });
  expect(edited.map(i => i.key)).toEqual(["user:u1", "user:q1", "user:q2"]);
  expect(edited[1]).toMatchObject({
    kind: "user",
    key: "user:q1",
    messageId: "q1",
    text: "edited in tab A",
    queued: true,
    receipt: true,
    attached: true,
    source: "remote-queue",
  });
  expect(edited[2]).toBe(initial[2]);
  const unchanged = applyStreamEvent(edited, {
    type: "user_message",
    eventId: "q1",
    data: { id: "q1", content: "edited in tab A", queued: true, source: "remote-queue" },
  });
  expect(unchanged).toBe(edited);
  const resynced = applyStreamEvents(
    buildTranscript([
      { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "first" } },
      { type: "user_message", eventId: "q1", data: { id: "q1", content: "edited in tab A", queued: true } },
      { type: "user_message", eventId: "q2", data: { id: "q2", content: "draft two", queued: true } },
    ]),
    edited
      .filter((i): i is Extract<(typeof edited)[number], { kind: "user" }> => i.kind === "user" && Boolean(i.queued && i.messageId))
      .map(i => ({ type: "user_message", data: { id: i.messageId, content: i.text, queued: true, receipt: i.receipt, attached: i.attached } })),
  );
  expect(resynced.map(i => i.kind === "user" ? `${i.key}:${i.text}:${Boolean(i.queued)}` : i.kind)).toEqual([
    "user:u1:first:false",
    "user:q1:edited in tab A:true",
    "user:q2:draft two:true",
  ]);
});

test("appending text ops on a long reply stay cheap", () => {
  let items = buildTranscript([{ type: "user_message", data: { id: "u1", content: "hi" } }]);
  const started = performance.now();
  for (let i = 0; i < 4000; i++) {
    items = applyStreamEvent(items, { type: "text_op", data: { bubble_id: "b", ops: [{ type: "insert", pos: 999999, text: "word ".repeat(10) }] } });
  }
  expect(performance.now() - started).toBeLessThan(500);
  const bubble = items.at(-1);
  expect(bubble?.kind === "text" && bubble.text.length).toBe(4000 * 50);
  // Positions still count code points for an insert in the middle.
  items = applyStreamEvent(buildTranscript([]), { type: "text_op", data: { bubble_id: "c", ops: [{ type: "insert", pos: 0, text: "héllo" }, { type: "insert", pos: 2, text: "X" }] } });
  const middle = items.at(-1);
  expect(middle?.kind === "text" && middle.text).toBe("héXllo");
});

test("cold-start disk hydration rebuilds reducer state for sessioned and session-less live patches", async () => {
  cacheReset();
  forgetPrefetchPauses();
  setConnection("https://orb-hydrate.example", "tok-hydrate");
  try {
    const stream = [
      { type: "user_message" as const, eventId: "u-disk-1", sequence: 1, data: { id: "u-disk-1", content: "check status" } },
      { type: "tool_call" as const, eventId: "tc-disk-1", sequence: 2, data: { tool_call_id: "call-disk-1", name: "bash", args: { command: "pwd" } } },
    ];
    const liveTail = [
      { type: "text_delta" as const, data: { content: "Working", mode: "delta" } },
    ];
    const rawItems = buildTranscript([...stream, ...liveTail]);
    const structuredClonedPersisted = structuredClone({
      items: rawItems,
      stream,
      liveTail,
      fromLog: true,
      cursor: 2,
    });
    clearTranscriptSessions();

    await savePersistedTranscript(historyScope(), "cold-mission", structuredClonedPersisted);

    const release = retainTranscript("cold-mission");
    try {
      const hydrated = await hydrateTranscriptFromDisk("cold-mission");
      expect(hydrated).toBeDefined();
      expect(hydrated!.items).not.toBe(structuredClonedPersisted.items);

      const sessionless = applyStreamEvents(hydrated!.items, [
        { type: "tool_call", eventId: "tc-disk-1", sequence: 2, data: { tool_call_id: "call-disk-1", name: "bash", args: { command: "pwd" } } },
        { type: "tool_result", eventId: "tr-disk-1", sequence: 3, data: { tool_call_id: "call-disk-1", name: "bash", result: "/workspace" } },
      ]);
      const resolvedTool = sessionless.find(i => i.kind === "tool");
      expect(resolvedTool).toMatchObject({ kind: "tool", callId: "call-disk-1", done: true, result: "/workspace" });

      applyLiveEventsToTranscriptCache("cold-mission", [
        { type: "tool_call", eventId: "tc-disk-1", sequence: 2, data: { tool_call_id: "call-disk-1", name: "bash", args: { command: "pwd" } } },
        { type: "text_delta", sequence: 4, data: { content: "!", mode: "delta" } },
      ]);
      const updated = peekReadyTranscript("cold-mission");
      expect(updated?.items.filter(i => i.kind === "tool")).toHaveLength(1);
      expect(updated?.items.at(-1)).toMatchObject({ kind: "text", text: "Working!" });
    } finally {
      release();
    }

    expect(() =>
      applyStreamEvents([{ kind: "user", key: "foreign", text: "forged" }], [
        { type: "text_delta", data: { content: "x", mode: "delta" } },
      ]),
    ).toThrow("Transcript must originate from buildTranscript");
  } finally {
    clearConnection();
    vi.unstubAllGlobals();
  }
});

test("divergent timelines and spine previews do not corrupt reducer indexes across older snapshots", async () => {
  cacheReset();
  forgetPrefetchPauses();
  setConnection("https://orb-diverge.example", "tok-diverge");
  try {
    const baseEvents = [
      { type: "user_message" as const, eventId: "u1", sequence: 1, data: { id: "u1", content: "run build" } },
      { type: "tool_call" as const, eventId: "tc1", sequence: 2, data: { tool_call_id: "call-1", name: "bash", args: { command: "make" } } },
      { type: "user_message" as const, eventId: "q1", data: { id: "q1", content: "queued note", queued: true } },
    ];
    const snap1Items = buildTranscript(baseEvents, transcriptSessionKey("m-div", connectionVersion()));
    putTranscript("m-div", { items: snap1Items, stream: baseEvents.slice(0, 2), fromLog: true, cursor: 2 });

    // Advance cached session timeline while caller still holds older `snap1Items`
    // (or a shallow copy / filtered copy that triggers divergent reindexFromItems).
    applyLiveEventsToTranscriptCache("m-div", [
      { type: "tool_result", eventId: "tr1", sequence: 3, data: { tool_call_id: "call-1", name: "bash", result: "ok" } },
      { type: "assistant_message", eventId: "a1", sequence: 4, data: { content: "Build succeeded." } },
      { type: "user_message", eventId: "u2", sequence: 5, data: { id: "u2", content: "next step" } },
    ]);

    // Session-less caller holding an older snapshot (MissionView / Inbox):
    // strip `q1` from `snap1Items` directly so `removeUsers` resolves via `anonymous`
    // (`sameTimeline` matches `snap1Items`), then apply the SAME live events (`tr1`, `a1`)
    // that the advanced session timeline already deduped.
    const trimmedOld = removeUsers(snap1Items, u => u.messageId === "q1");
    const patchedOld = applyStreamEvents(trimmedOld, [
      { type: "tool_result", eventId: "tr1", sequence: 3, data: { tool_call_id: "call-1", name: "bash", result: "ok-on-old" } },
      { type: "assistant_message", eventId: "a1", sequence: 4, data: { content: "Build succeeded." } },
    ]);
    expect(patchedOld.find(i => i.kind === "tool")).toMatchObject({
      kind: "tool",
      callId: "call-1",
      done: true,
      result: "ok-on-old",
    });
    expect(patchedOld.find(i => i.kind === "text")).toMatchObject({
      kind: "text",
      text: "Build succeeded.",
      live: false,
    });

    // Also cover BOTH divergent `reindexFromItems` fallbacks:
    // (a) `exact.reindexFromItems(items)` when an array registered in `anonymous` has diverged,
    // (b) `history[history.length - 1].reindexFromItems(items)` when an older divergent array
    //     misses `sameTimeline` across the 4-entry session history (after >4 distinct item-count steps)
    //     and hands the resulting snapshot to a session-less caller.
    for (let step = 10; step < 15; step++) {
      applyLiveEventsToTranscriptCache("m-div", [
        { type: "user_message", eventId: `u-${step}`, sequence: step, data: { id: `u-${step}`, content: `step ${step}` } },
      ]);
    }
    const reindexedFromAdvancedHistory = removeUsers(
      snap1Items.slice(),
      u => u.messageId === "q1",
      transcriptSessionKey("m-div", connectionVersion()),
    );
    const patchedAfterHistoryReindex = applyStreamEvents(reindexedFromAdvancedHistory, [
      { type: "tool_result", eventId: "tr1", sequence: 3, data: { tool_call_id: "call-1", name: "bash", result: "ok-after-reindex" } },
      { type: "assistant_message", eventId: "a1", sequence: 4, data: { content: "Build succeeded after reindex." } },
    ]);
    expect(patchedAfterHistoryReindex.find(i => i.kind === "tool")).toMatchObject({
      kind: "tool",
      callId: "call-1",
      done: true,
      result: "ok-after-reindex",
    });
    expect(patchedAfterHistoryReindex.find(i => i.kind === "text")).toMatchObject({
      kind: "text",
      text: "Build succeeded after reindex.",
      live: false,
    });

    // Cached advanced snapshot must remain uncorrupted by operations on the older branch.
    applyLiveEventsToTranscriptCache("m-div", [
      { type: "tool_call", eventId: "tc2", sequence: 20, data: { tool_call_id: "call-2", name: "read", args: { file: "a.ts" } } },
      { type: "tool_result", eventId: "tr2", sequence: 21, data: { tool_call_id: "call-2", name: "read", result: "export {}" } },
    ]);
    const latest = peekReadyTranscript("m-div")!;
    expect(latest.items.filter(i => i.kind === "tool").map(t => [t.callId, t.done, t.result])).toEqual([
      ["call-1", true, "ok"],
      ["call-2", true, "export {}"],
    ]);

    // Also verify presentation preview refresh marks the spine-preview snapshot `detailsPending: true`
    // (so `peekReadyTranscript` never exposes a tool-stripped preview fold), uses an isolated preview
    // session key, and allows a later full `loadTranscript` fetch to clear `detailsPending`.
    putTranscript("m-preview", { items: buildTranscript(baseEvents), stream: baseEvents.slice(0, 1), fromLog: true, cursor: 2 });
    const releasePreview = retainTranscript("m-preview");
    releasePreview();
    const activeSession = transcriptSessionKey("m-preview", connectionVersion());
    const fullItems = buildTranscript(baseEvents, activeSession);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.includes("profile=presentation")) {
          return new Response(
            JSON.stringify({
              profile: "presentation",
              activity: "Thinking…",
              events: [
                { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "run build", timestamp: "" },
                { id: 9, event_id: "a9", sequence: 9, event_type: "assistant_message", content: "spine preview reply", timestamp: "" },
              ],
            }),
            { headers: { "Content-Type": "application/json" } },
          );
        }
        if (url.includes("/queue")) {
          return new Response(JSON.stringify([]), { headers: { "Content-Type": "application/json" } });
        }
        return new Response(
          JSON.stringify([
            { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "run build", timestamp: "" },
            { id: 2, event_id: "tc1", sequence: 2, event_type: "tool_call", tool_call_id: "call-1", tool_name: "bash", content: JSON.stringify({ command: "make" }), timestamp: "" },
            { id: 3, event_id: "tr1", sequence: 3, event_type: "tool_result", tool_call_id: "call-1", tool_name: "bash", content: JSON.stringify("ok"), timestamp: "" },
            { id: 9, event_id: "a9", sequence: 9, event_type: "assistant_message", content: "spine preview reply", timestamp: "" },
          ]),
          {
            headers: {
              "Content-Type": "application/json",
              "X-Orb-Events-Protocol": "1",
              "X-Has-More": "false",
              "X-Next-Cursor": "9",
              "X-Page-Max-Sequence": "9",
            },
          },
        );
      }),
    );
    await refreshPresentationPreview("m-preview");
    expect(peekReadyTranscript("m-preview")).toBeUndefined();
    expect(peekTranscript("m-preview")).toMatchObject({
      activity: "Thinking…",
      fromLog: true,
      detailsPending: true,
    });
    const afterFull = applyStreamEvent(
      fullItems.slice(),
      { type: "tool_result", eventId: "tr1", sequence: 3, data: { tool_call_id: "call-1", name: "bash", result: "unclobbered" } },
      activeSession,
    );
    expect(afterFull.find(i => i.kind === "tool")).toMatchObject({
      kind: "tool",
      callId: "call-1",
      done: true,
      result: "unclobbered",
    });
    const hydratedFull = await loadTranscript("m-preview");
    expect(hydratedFull.detailsPending).toBeFalsy();
    expect(peekReadyTranscript("m-preview")?.items.some(i => i.kind === "tool" && i.callId === "call-1" && i.done)).toBe(true);
  } finally {
    clearConnection();
    vi.unstubAllGlobals();
  }
});
