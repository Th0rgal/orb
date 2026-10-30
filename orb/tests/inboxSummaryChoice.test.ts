import { describe, expect, it } from "vitest";
import choiceFixture from "../../shared/orb-spec/fixtures/inbox-summary-choice.json";
import policyFixture from "../../shared/orb-spec/fixtures/inbox-summary-policy.json";
import {
  ECO_QUIET_MS,
  inboxSummaryChoice,
  normalizeInboxConfig,
  shouldRequestInboxDigest,
  type InboxSummarySurface,
} from "../src/inboxSettings";

describe("shared Inbox summary selection", () => {
  for (const test of choiceFixture.cases) it(test.name, () => {
    let model = test.initial;
    test.choices.forEach((choice, index) => {
      const result = inboxSummaryChoice(model, choice);
      expect(result).toEqual(test.expected[index]);
      model = result.model;
    });
  });
});

describe("shared Inbox & summary policy", () => {
  it("matches the shared Eco quiet window", () => {
    expect(ECO_QUIET_MS).toBe(policyFixture.ecoQuietMs);
  });
  for (const c of policyFixture.normalization) {
    it(`normalization: ${c.name}`, () => {
      expect(normalizeInboxConfig(c.input)).toEqual(c.expected);
    });
  }
  for (const g of policyFixture.gates) {
    it(`gate: ${g.name}`, () => {
      expect(
        shouldRequestInboxDigest(
          g.prefs,
          g.surface as InboxSummarySurface,
          g.isLive,
          g.updatedMs,
          g.nowMs,
        ),
      ).toBe(g.expected);
    });
  }
});
