/** Provider quota and rate-limit failures, recognized from the messages the
 * harnesses actually emit (same markers as src/api/runners/errors.rs). */
export type ProviderLimit = { kind: "quota" | "rate"; provider?: string; resets?: string; url?: string };

const QUOTA = /usageLimitExceeded|hit your (?:usage )?limit|usage limit (?:reached|exceeded)|weekly (?:usage )?(?:limit|quota) (?:reached|exhausted|exceeded)|out of (?:usage |extra usage|regular usage)?credits|out of (?:extra|regular) usage|purchase more credits|insufficient_quota|quota exceeded|Claude AI usage limit reached/i;
// Google reports per-minute throttling as RESOURCE_EXHAUSTED; the backend treats it as transient too.
const RATE = /\b(?:429|529)\b|too many requests|overloaded_error|RESOURCE_EXHAUSTED|rate[ _]limit(?:ed| reached| exceeded|_error)?/i;

function provider(raw: string): string | undefined {
  if (/codexErrorInfo|chatgpt\.com\/codex|\bcodex\b/i.test(raw)) return "Codex";
  if (/\bclaude\b|anthropic/i.test(raw)) return "Claude";
  if (/\bgrok\b|\bx\.ai\b|\bxai\b/i.test(raw)) return "Grok";
  if (/\bgemini\b/i.test(raw)) return "Gemini";
  if (/\bcursor\b/i.test(raw)) return "Cursor";
  return undefined;
}

function resets(raw: string): string | undefined {
  const epoch = raw.match(/usage limit reached\|(\d{10})\b/i);
  if (epoch) return new Date(Number(epoch[1]) * 1000).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  const at = raw.match(/try again (?:at|on|after) ([^.'"\n]+(?:\d{1,2}:\d{2}\s*[AP]M)?)/i) ?? raw.match(/resets?(?: at| on)? ([^.'"\n·|]+)/i);
  return at?.[1].replace(/(\d)(?:st|nd|rd|th)\b/g, "$1").trim();
}

/** "at 9pm" for a time of day, "on Oct 3, 2026 6:58 PM" for a date. */
export function resetPhrase(when: string): string {
  return /^\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?$/i.test(when) ? `at ${when}` : `on ${when}`;
}

export function providerLimit(raw: string): ProviderLimit | undefined {
  // Orb's own API errors start with their HTTP status. A throttled login or
  // settings call is not an AI provider limit unless the body names one.
  if (/^\s*\d{3}\b/.test(raw) && !QUOTA.test(raw) && !provider(raw)) return undefined;
  const kind = QUOTA.test(raw) ? "quota" : RATE.test(raw) ? "rate" : undefined;
  if (!kind) return undefined;
  const url = raw.match(/https:\/\/[^\s'"<>)]+/)?.[0].replace(/[.,;]+$/, "");
  return { kind, provider: provider(raw), resets: kind === "quota" ? resets(raw) : undefined, url };
}
