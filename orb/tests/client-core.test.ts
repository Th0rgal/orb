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
  verifyBundleBudget,
  verifyClientSyncCursor,
  type SyncCursorState,
} from "../src/clientCore";

type ClientCoreCase =
  | {
      op: "syncCursor";
      name: string;
      localEpoch: number;
      incomingEpoch: number;
      localSeq: number;
      incomingSeq: number;
      frameValid: boolean;
      authOk: boolean;
      expectedAdmitted: boolean;
      expectedStepped: boolean;
      expectedEpoch: number;
      expectedSeq: number;
    }
  | {
      op: "projectTranscript";
      name: string;
      userTurns: number;
      toolTurns: number;
      thinkingOpen: boolean;
      isReplay: boolean;
      expectedVisibleEntries: number;
      expectedThinkingActive: boolean;
    }
  | {
      op: "bundleBudget";
      name: string;
      eagerBytes: number;
      budgetBytes: number;
      singleAppEntry: boolean;
      hasEagerHeavyVendor: boolean;
      expectedAdmitted: boolean;
    }
  | {
      op: "parsePatch";
      name: string;
      rawHex: string;
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
    expect(fixture.cases.length).toBeGreaterThanOrEqual(25);
    for (const c of fixture.cases) {
      if (c.op === "syncCursor") {
        expect(
          verifyClientSyncCursor(
            c.localEpoch,
            c.incomingEpoch,
            c.localSeq,
            c.incomingSeq,
            c.frameValid,
            c.authOk,
          ),
          c.name,
        ).toBe(c.expectedAdmitted);
        const res = stepSyncCursor(
          { epoch: BigInt(c.localEpoch), seq: BigInt(c.localSeq) },
          c.incomingEpoch,
          c.incomingSeq,
          c.frameValid,
          c.authOk,
        );
        expect(res.stepped, c.name).toBe(c.expectedStepped);
        expect(res.state.epoch, c.name).toBe(BigInt(c.expectedEpoch));
        expect(res.state.seq, c.name).toBe(BigInt(c.expectedSeq));
      } else if (c.op === "projectTranscript") {
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
            c.eagerBytes,
            c.budgetBytes,
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
          expect(bytesToHex(parsed!), c.name).toBe(c.expectedPayloadHex);
        }
      }
    }
  });

  it("satisfies cursor irreflexivity, replay invariance, and ORBP roundtrip across 300 fuzz seeds", () => {
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

      // Replay projection invariance theorem
      const u = nextU32() % 4096;
      const t = nextU32() % 4096;
      const think = (nextU32() & 1) === 1;
      expect(projectTranscriptCounts(u, t, think, false)).toEqual(
        projectTranscriptCounts(u, t, think, true),
      );

      // ORBP roundtrip & bounded slice cap
      const payLen = 1 + (nextU32() % 512);
      const schema = 1 + (nextU32() % 255);
      const payload = new Uint8Array(payLen);
      for (let j = 0; j < payLen; j++) payload[j] = nextU32() & 0xff;
      const encoded = encodeOrbClientPatch(schema, payload);
      expect(encoded).not.toBeNull();
      const decoded = parseOrbClientPatch(encoded!);
      expect(decoded).not.toBeNull();
      expect(decoded!.byteLength).toBeLessThanOrEqual(ORB_PATCH_MAX_PAYLOAD_BYTES);
      expect(decoded).toEqual(payload);
    }
  });
});
