export const BTW_PROMPT_PREAMBLE = "You are the independent /btw agent sharing the main agent's working folder.";
const BTW_REQUEST_MARKER = "\nCurrent request:\n";
const BTW_ATTACHMENT_TRAILER = /(?:\nAttachment: [^\n]+)+\s*$/;

export function isBtwWrappedPrompt(content: string): boolean {
  return content.trimStart().startsWith(BTW_PROMPT_PREAMBLE) && content.includes(BTW_REQUEST_MARKER);
}

export function extractBtwUserQuestion(content: string): string {
  const idx = content.lastIndexOf(BTW_REQUEST_MARKER);
  const raw = idx >= 0 ? content.slice(idx + BTW_REQUEST_MARKER.length) : content;
  return raw.replace(BTW_ATTACHMENT_TRAILER, "").trim();
}

export function extractBtwAttachmentPaths(content: string): string[] {
  const idx = content.lastIndexOf(BTW_REQUEST_MARKER);
  const body = idx >= 0 ? content.slice(idx + BTW_REQUEST_MARKER.length) : content;
  const attachMatch = BTW_ATTACHMENT_TRAILER.exec(body);
  if (!attachMatch) return [];
  return attachMatch[0]
    .trim()
    .split("\n")
    .map(line => line.replace(/^Attachment:\s*/, "").trim())
    .filter(Boolean);
}

/** Replace only the user's question inside a wrapped `/btw` prompt so in-place
 * queue edits preserve `<main_conversation_update>` and `Attachment:` lines. */
export function replaceBtwUserQuestion(content: string, nextQuestion: string): string {
  const idx = content.lastIndexOf(BTW_REQUEST_MARKER);
  if (idx < 0) return nextQuestion;
  const prefix = content.slice(0, idx + BTW_REQUEST_MARKER.length);
  const body = content.slice(idx + BTW_REQUEST_MARKER.length);
  const attachMatch = BTW_ATTACHMENT_TRAILER.exec(body);
  const suffix = attachMatch ? `\n${attachMatch[0].trim()}` : "\n";
  return `${prefix}${nextQuestion.trim()}${suffix}`.replace(/\n+$/, match => (attachMatch ? "" : match.slice(0, 1)));
}

/** Hide only the exact server-generated attachment transport trailer and `/btw`
 * context wrapper. The model retains the original text for replay; the UI
 * reports context without exposing staging paths or system preambles. */
export function messagePresentation(content: string): { text: string; attached: boolean } {
  const trailer = /\n\n<!-- paloma:attachment:([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}) -->\nAttached context: read `\.paloma\/messages\/\1\/\.paloma\/attach\.md` \(paths in that manifest are relative to `\.paloma\/messages\/\1`\)\.$/i;
  const match = trailer.exec(content);
  const unwrapped = match ? content.slice(0, match.index) : content;
  if (isBtwWrappedPrompt(unwrapped)) {
    const idx = unwrapped.lastIndexOf(BTW_REQUEST_MARKER);
    const body = idx >= 0 ? unwrapped.slice(idx + BTW_REQUEST_MARKER.length) : unwrapped;
    const hasBtwAttach = BTW_ATTACHMENT_TRAILER.test(body);
    return { text: extractBtwUserQuestion(unwrapped), attached: Boolean(match) || hasBtwAttach };
  }
  return match ? { text: unwrapped, attached: true } : { text: content, attached: false };
}

/** Sent by the Resume button; shown collapsed so it doesn't read like a user turn. */
export const resumePrompt='Your previous turn was interrupted before it finished. Check what is already done, then continue from there. Do not redo finished work.';
export const isResumePrompt = (content: string) => content.trim() === resumePrompt;

/** Exact coordinator markers; a user's normal request to resume stays a user turn. */
export function isAutomaticRecovery(content: string): boolean {
  return /^\[Automatic (?:recovery|resume after a usage limit)\]/i.test(content.trimStart());
}
