/**
 * Glued opening code fences: agents occasionally emit an opening triple-backtick
 * fence directly at the end of a prose sentence without a preceding newline
 * (e.g. `Let's present the updated diagram cleanly!```mermaid`), causing
 * line-initial fence checks (`trimmed.startsWith("```")`) to miss the opening
 * fence and treat the closing ` ``` ` as opening a new unclosed code block.
 *
 * Shared with iOS (OrbCodeFences.swift) and Android (OrbCodeFences.kt); rules
 * and test cases live in shared/orb-spec/fixtures/glued-code-fences.json.
 */

export type GluedFence = { offset: number; lang: string };

function isAsciiAlpha(code: number): boolean {
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isFenceLangChar(code: number): boolean {
  return (
    isAsciiAlpha(code) ||
    (code >= 48 && code <= 57) ||
    code === 95 || // _
    code === 43 || // +
    code === 46 || // .
    code === 35 || // #
    code === 45 // -
  );
}

/**
 * If `line` (outside an open fence) ends with an unmatched ` ```<lang> ` glued
 * after non-empty prose, returns the split offset of ` ``` ` and `<lang>`.
 */
export function splitGluedFence(line: string): GluedFence | null {
  const cleanLen = line.endsWith("\r") ? line.length - 1 : line.length;
  if (cleanLen < 5 || !line.includes("```")) return null;

  let lead = 0;
  while (lead < cleanLen && (line.charCodeAt(lead) === 32 || line.charCodeAt(lead) === 9)) lead++;
  if (lead >= cleanLen) return null;

  const first = line.charCodeAt(lead);
  if (first === 124 || first === 62) return null; // `|` or `>`
  if ((first === 96 || first === 126) && lead + 2 < cleanLen && line.charCodeAt(lead + 1) === first && line.charCodeAt(lead + 2) === first) {
    return null;
  }

  let i = lead;
  while (i < cleanLen) {
    const ch = line.charCodeAt(i);
    if (ch === 92 && i + 1 < cleanLen) {
      i += 2;
      continue;
    }
    if (ch === 96) {
      const tickStart = i;
      while (i < cleanLen && line.charCodeAt(i) === 96) i++;
      const ticks = i - tickStart;

      let j = i;
      let closedAt = -1;
      while (j + ticks <= cleanLen) {
        if (line.charCodeAt(j) === 96) {
          const runStart = j;
          while (j < cleanLen && line.charCodeAt(j) === 96) j++;
          if (j - runStart === ticks) {
            closedAt = runStart;
            break;
          }
        } else {
          j++;
        }
      }
      if (closedAt !== -1) {
        i = closedAt + ticks;
        continue;
      }

      if (ticks === 3 && tickStart > lead && i < cleanLen && isAsciiAlpha(line.charCodeAt(i))) {
        let k = i + 1;
        while (k < cleanLen && isFenceLangChar(line.charCodeAt(k))) k++;
        const langLen = k - i;
        if (langLen <= 32) {
          let m = k;
          while (m < cleanLen && (line.charCodeAt(m) === 32 || line.charCodeAt(m) === 9)) m++;
          if (m === cleanLen && line.slice(0, tickStart).trim().length > 0) {
            return { offset: tickStart, lang: line.slice(i, k) };
          }
        }
      }
      continue;
    }
    i++;
  }
  return null;
}

/** Split glued opening code fences onto their own line outside existing fences. */
export function normalizeGluedFences(src: string): string {
  let nextTicks = src.indexOf("```", 0);
  if (nextTicks === -1) return src;

  let inFence = false;
  let hasGlued = false;
  let lineStart = 0;
  while (lineStart <= src.length) {
    const nl = src.indexOf("\n", lineStart);
    const lineEnd = nl === -1 ? src.length : nl;
    while (nextTicks !== -1 && nextTicks < lineStart) nextTicks = src.indexOf("```", lineStart);
    if (nextTicks === -1) break;
    if (nextTicks < lineEnd) {
      const rawLine = src.slice(lineStart, lineEnd);
      if (rawLine.trimStart().startsWith("```")) {
        inFence = !inFence;
      } else if (!inFence && splitGluedFence(rawLine)) {
        hasGlued = true;
        break;
      }
    }
    if (nl === -1) break;
    lineStart = nl + 1;
  }
  if (!hasGlued) return src;

  const lines = src.split("\n");
  const out: string[] = [];
  inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trimStart().startsWith("```")) {
      inFence = !inFence;
      out.push(line);
      continue;
    }
    if (!inFence) {
      const glued = splitGluedFence(line);
      if (glued) {
        out.push(line.slice(0, glued.offset), line.slice(glued.offset));
        inFence = true;
        continue;
      }
    }
    out.push(line);
  }
  return out.join("\n");
}
