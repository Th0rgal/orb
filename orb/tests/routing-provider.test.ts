import { expect, test } from "vitest";
import fixture from "../../shared/orb-spec/fixtures/routing-provider.json";
import { routingProvider, routingProviderLabel } from "../src/routingProvider";

test.each(fixture.cases)("routing provider alias $id", c => {
  expect(routingProvider(fixture.catalog, c.id)?.id ?? null).toBe(c.canonical);
  expect(routingProviderLabel(fixture.catalog, c.id)).toBe(c.label);
});
