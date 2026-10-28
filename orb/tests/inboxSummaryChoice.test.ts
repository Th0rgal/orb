import { describe, expect, it } from "vitest";
import fixture from "../../shared/orb-spec/fixtures/inbox-summary-choice.json";
import { inboxSummaryChoice } from "../src/inboxSettings";

describe("shared Inbox summary selection", () => {
  for (const test of fixture.cases) it(test.name, () => {
    let model = test.initial;
    test.choices.forEach((choice, index) => {
      const result = inboxSummaryChoice(model, choice);
      expect(result).toEqual(test.expected[index]);
      model = result.model;
    });
  });
});
