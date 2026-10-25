import { expect, it } from "vitest";
import { providerLimit } from "../src/usageLimit";

it("reads a Gemini per-minute throttle as a wait, not as an exhausted quota", () => {
  expect(providerLimit("gemini: 429 RESOURCE_EXHAUSTED: please retry in 12s")?.kind).toBe("rate");
  expect(providerLimit("RESOURCE_EXHAUSTED")?.kind).toBe("rate");
  expect(providerLimit("RESOURCE_EXHAUSTED: quota exceeded for this billing account")?.kind).toBe("quota");
  expect(providerLimit("You've hit your usage limit. Try again at 9pm.")?.kind).toBe("quota");
});

it("does not read a throttled Orb API call as a provider limit", () => {
  expect(providerLimit("429 Too Many Requests")).toBeUndefined();
  expect(providerLimit('429 {"error":"rate limited"}')).toBeUndefined();
  expect(providerLimit("429 Codex usage limit reached")?.kind).toBe("quota");
  expect(providerLimit("Anthropic API error: 529 overloaded_error")?.kind).toBe("rate");
});

it("leaves a filesystem quota error alone", () => {
  expect(providerLimit("Disk quota exceeded (os error 122)")).toBeUndefined();
  expect(providerLimit("Gemini: quota exceeded for this project")?.kind).toBe("quota");
});

it("reads an Antigravity individual quota refusal as an exhausted quota with its reset", () => {
  const raw = "CLI error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 129h43m31s. (RESOURCE_EXHAUSTED (code 429)) AGY_ERROR";
  const limit = providerLimit(raw);
  expect(limit?.kind).toBe("quota");
  expect(limit?.provider).toBe("Antigravity");
  expect(limit?.resets).toBeTruthy();
  expect(limit?.resets).not.toMatch(/^in /);
});
