import { expect, it } from "vitest";
import { providerLimit } from "../src/usageLimit";

it("reads a Gemini per-minute throttle as a wait, not as an exhausted quota", () => {
  expect(providerLimit("gemini: 429 RESOURCE_EXHAUSTED: please retry in 12s")?.kind).toBe("rate");
  expect(providerLimit("RESOURCE_EXHAUSTED")?.kind).toBe("rate");
  expect(providerLimit("RESOURCE_EXHAUSTED: quota exceeded for this billing account")?.kind).toBe("quota");
  expect(providerLimit("You've hit your usage limit. Try again at 9pm.")?.kind).toBe("quota");
});
