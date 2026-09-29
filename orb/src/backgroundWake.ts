/** The coordinator's wake message after a Claude Code background shell ends
 * (`src/api/supervision/bg_autoresume.rs`). Older events carry no source, so
 * the fixed server wording identifies them. */
export interface BackgroundWake { task: string; command: string; output: string; killed: boolean; note: string }

const WAKE = /^Background task `([^`\n]+)` \(`([\s\S]*)`\) finished\.(?: Output:\n\n```\n([\s\S]*)\n```| \(No captured output was available\.\)(.*))([\s\S]*?)\n\nContinue from here\.$/;

export function backgroundWake(text: string, source?: string): BackgroundWake | null {
  if (source && source !== "background-task") return null;
  const match = WAKE.exec(text);
  if (!match) return null;
  const output = (match[3] ?? "").trim();
  const note = ((match[4] ?? "") + (match[5] ?? "")).replace(/^\s*\(Note: |\)$/g, "").replace(/^\s*\(|\)\s*$/g, "").trim();
  return { task: match[1], command: match[2], output, killed: output === "[killed]", note };
}
