import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  ORB_PATCH_MAX_PAYLOAD_BYTES,
  encodeOrbClientPatch,
  parseOrbClientPatch,
  projectTranscriptCounts,
  stepSyncCursor,
  validTranscriptProjInput,
  verifyBundleBudget,
  verifyClientSyncCursor,
  type SyncCursorState,
} from "../src/clientCore";

type ClientCoreCase =
  | {
      op: "syncCursor";
      name: string;
      localEpoch: string;
      incomingEpoch: string;
      localSeq: string;
      incomingSeq: string;
      frameValid: boolean;
      authOk: boolean;
      expectedAdmitted: boolean;
      expectedStepped: boolean;
      expectedEpoch: string;
      expectedSeq: string;
    }
  | {
      op: "projectTranscript";
      name: string;
      userTurns: number;
      toolTurns: number;
      thinkingOpen: boolean;
      isReplay: boolean;
      expectedValidDomain: boolean;
      expectedVisibleEntries: number;
      expectedThinkingActive: boolean;
    }
  | {
      op: "bundleBudget";
      name: string;
      eagerBytes: string;
      budgetBytes: string;
      singleAppEntry: boolean;
      hasEagerHeavyVendor: boolean;
      expectedAdmitted: boolean;
    }
  | {
      op: "parsePatch";
      name: string;
      rawHex: string;
      expectedSchema: number | null;
      expectedPayloadHex: string | null;
    };

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = Number.parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

const fixturePath = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "shared",
  "orb-spec",
  "fixtures",
  "client-core.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { cases: ClientCoreCase[] };

describe("shared/orb-spec/fixtures/client-core.json (lean/OrbClient)", () => {
  it("matches every Lean-generated OrbClient fixture case", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(30);
    for (const c of fixture.cases) {
      if (c.op === "syncCursor") {
        const le = BigInt(c.localEpoch);
        const ie = BigInt(c.incomingEpoch);
        const ls = BigInt(c.localSeq);
        const isq = BigInt(c.incomingSeq);
        expect(
          verifyClientSyncCursor(
            le,
            ie,
            ls,
            isq,
            c.frameValid,
            c.authOk,
          ),
          c.name,
        ).toBe(c.expectedAdmitted);
        const res = stepSyncCursor(
          { epoch: le, seq: ls },
          ie,
          isq,
          c.frameValid,
          c.authOk,
        );
        expect(res.stepped, c.name).toBe(c.expectedStepped);
        expect(res.state.epoch, c.name).toBe(BigInt(c.expectedEpoch));
        expect(res.state.seq, c.name).toBe(BigInt(c.expectedSeq));
      } else if (c.op === "projectTranscript") {
        expect(validTranscriptProjInput(c.userTurns, c.toolTurns), c.name).toBe(
          c.expectedValidDomain,
        );
        const out = projectTranscriptCounts(
          c.userTurns,
          c.toolTurns,
          c.thinkingOpen,
          c.isReplay,
        );
        expect(out, c.name).toEqual({
          visibleEntries: c.expectedVisibleEntries,
          thinkingActive: c.expectedThinkingActive,
        });
      } else if (c.op === "bundleBudget") {
        expect(
          verifyBundleBudget(
            BigInt(c.eagerBytes),
            BigInt(c.budgetBytes),
            c.singleAppEntry,
            c.hasEagerHeavyVendor,
          ),
          c.name,
        ).toBe(c.expectedAdmitted);
      } else if (c.op === "parsePatch") {
        const parsed = parseOrbClientPatch(hexToBytes(c.rawHex));
        if (c.expectedPayloadHex === null) {
          expect(parsed, c.name).toBeNull();
        } else {
          expect(parsed, c.name).not.toBeNull();
          expect(parsed!.schema, c.name).toBe(c.expectedSchema);
          expect(bytesToHex(parsed!.payload), c.name).toBe(c.expectedPayloadHex);
        }
      }
    }
  });

  it("fails closed on out-of-domain JS numbers (negative, NaN, float, > UInt32/UInt64)", () => {
    expect(projectTranscriptCounts(-1, 5, false, false)).toBeNull();
    expect(projectTranscriptCounts(5, Number.NaN, false, false)).toBeNull();
    expect(projectTranscriptCounts(1.5, 2, true, false)).toBeNull();
    expect(projectTranscriptCounts(2 ** 32, 0, false, false)).toBeNull();
    expect(validTranscriptProjInput(-1, 0)).toBe(false);
    expect(validTranscriptProjInput(65_537, 0)).toBe(false);
    expect(verifyClientSyncCursor(-1, 1, 0, 1, true, true)).toBe(false);
    expect(verifyClientSyncCursor(0n, 1n << 64n, 0n, 1n, true, true)).toBe(false);
    expect(verifyBundleBudget(-1, 1000, true, false)).toBe(false);
    expect(verifyBundleBudget(1000n, 1n << 64n, true, false)).toBe(false);
  });

  it("satisfies cursor irreflexivity, replay invariance, and ORBP schema+payload roundtrip across 300 fuzz seeds", () => {
    let seedState = 0x517cc1b7;
    const nextU32 = () => {
      seedState ^= seedState << 13;
      seedState ^= seedState >>> 17;
      seedState ^= seedState << 5;
      return seedState >>> 0;
    };

    let cur: SyncCursorState = { epoch: 0n, seq: 0n };
    for (let i = 0; i < 300; i++) {
      const ep = BigInt(nextU32() % 8);
      const sq = BigInt(nextU32() % 64);
      // Irreflexivity theorem: verifyClientSyncCursor ep ep sq sq fv ao = false
      expect(verifyClientSyncCursor(ep, ep, sq, sq, true, true)).toBe(false);

      const stepped = stepSyncCursor(cur, ep, sq, (nextU32() & 1) === 1, (nextU32() & 1) === 1);
      if (stepped.stepped) {
        expect(
          stepped.state.epoch > cur.epoch ||
            (stepped.state.epoch === cur.epoch && stepped.state.seq > cur.seq),
        ).toBe(true);
        cur = stepped.state;
      } else {
        expect(stepped.state).toEqual(cur);
      }

      // Replay projection invariance & non-wrapping theorem on valid domain
      const u = nextU32() % 4096;
      const t = nextU32() % 4096;
      const think = (nextU32() & 1) === 1;
      expect(validTranscriptProjInput(u, t)).toBe(true);
      const liveProj = projectTranscriptCounts(u, t, think, false);
      const replayProj = projectTranscriptCounts(u, t, think, true);
      expect(liveProj).toEqual(replayProj);
      expect(liveProj!.visibleEntries).toBe(u + t);

      // ORBP roundtrip (both schema and payload) & bounded slice cap
      const payLen = 1 + (nextU32() % 512);
      const schema = 1 + (nextU32() % 255);
      const payload = new Uint8Array(payLen);
      for (let j = 0; j < payLen; j++) payload[j] = nextU32() & 0xff;
      const encoded = encodeOrbClientPatch(schema, payload);
      expect(encoded).not.toBeNull();
      const decoded = parseOrbClientPatch(encoded!);
      expect(decoded).not.toBeNull();
      expect(decoded!.schema).toBe(schema);
      expect(decoded!.payload.byteLength).toBeLessThanOrEqual(ORB_PATCH_MAX_PAYLOAD_BYTES);
      expect(decoded!.payload).toEqual(payload);
    }
  });
});
