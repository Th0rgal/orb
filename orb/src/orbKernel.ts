export type WorkfoldVerdict = { foldItem: boolean; foldHasToolNext: boolean };

export function orbWorkfoldStep(
  itemKind: number,
  isCumulative: boolean,
  isNonEmpty: boolean,
  toolAhead: boolean,
  nextIsTool: boolean,
  foldHasTool: boolean,
): WorkfoldVerdict {
  let raw = 0;
  if (itemKind === 3) {
    raw = 257;
  } else if (itemKind === 1) {
    raw = foldHasTool ? 257 : 1;
  } else if (itemKind === 2) {
    if (!isCumulative && isNonEmpty && toolAhead && (foldHasTool || nextIsTool)) {
      raw = foldHasTool ? 257 : 1;
    }
  }
  return {
    foldItem: (raw & 1) !== 0,
    foldHasToolNext: ((raw >> 8) & 1) !== 0,
  };
}

export function orbTaskcardStep(
  turnEnded: boolean,
  allClosed: boolean,
  turnOutcomeFinished: boolean,
): "live" | "done" | "stale" | "stopped" {
  const code = !turnEnded ? 0 : allClosed ? 1 : turnOutcomeFinished ? 2 : 3;
  return code === 0 ? "live" : code === 1 ? "done" : code === 2 ? "stale" : "stopped";
}

export function orbRelativeTimeString(elapsedSecs: number): string {
  const s = Math.max(0, Math.floor(elapsedSecs));
  let unit = 0;
  let value = 0;
  if (s < 45) {
    unit = 0;
    value = 0;
  } else if (s < 3600) {
    unit = 1;
    value = Math.max(1, Math.floor(s / 60));
  } else if (s < 86_400) {
    unit = 2;
    value = Math.floor(s / 3600);
  } else if (s < 604_800) {
    unit = 3;
    value = Math.floor(s / 86_400);
  } else {
    unit = 4;
    value = Math.floor(s / 604_800);
  }
  return unit === 0 ? "now" : unit === 1 ? `${value}m` : unit === 2 ? `${value}h` : unit === 3 ? `${value}d` : `${value}w`;
}

export function orbUsageLimitBadge(
  status: string,
  claim: string,
  hasUtilization: boolean,
  utilizationPct: number,
  hasReset: boolean,
  resetRemSecs: number,
): { tone: "warning" | "error"; label: string } | null {
  const statusKind = !status || status === "allowed" || status === "ok" ? 0 : status === "allowed_warning" ? 1 : status === "rejected" ? 2 : 3;
  const claimKind =
    claim === "five_hour" ? 1 : claim === "seven_day" ? 2 : claim === "seven_day_opus" ? 3 : claim === "seven_day_sonnet" ? 4 : 0;
  if (statusKind === 0) return null;
  if (statusKind === 1) {
    const winLabel =
      claimKind === 1 ? "5h" : claimKind === 2 ? "weekly" : claimKind === 3 ? "weekly Opus" : claimKind === 4 ? "weekly Sonnet" : null;
    if (!winLabel) return { tone: "warning", label: "Approaching limit" };
    const showPct = (claimKind === 1 || claimKind === 2) && hasUtilization && utilizationPct >= 0 && utilizationPct <= 100;
    const pct = showPct ? ` ${Math.round(utilizationPct)}%` : "";
    return { tone: "warning", label: `Approaching limit · ${winLabel}${pct}` };
  }
  if (statusKind === 2) {
    const rem = Math.floor(resetRemSecs);
    if (!hasReset || !(rem > 0)) return { tone: "error", label: "Limit reached" };
    const mins = Math.floor(rem / 60);
    const hrs = Math.floor(rem / 3600);
    const days = Math.floor(rem / 86_400);
    const span = mins < 60 ? `${Math.max(1, mins)}m` : hrs < 48 ? `${hrs}h` : `${days}d`;
    return { tone: "error", label: `Limit reached · resets in ${span}` };
  }
  return { tone: "warning", label: "Limit status unknown" };
}

const U32_MAX = 0xffff_ffff;
const satAdd32 = (a: number, b: number) => Math.min(U32_MAX, a + b);

export type TranscriptPatchState = { len: number; seq: number };

export function orbTranscriptPatchStep(state: TranscriptPatchState, eventKind: number, deltaLen: number): TranscriptPatchState {
  if (eventKind < 0 || eventKind > 2) return state;
  const len = eventKind === 2 ? 0 : eventKind === 1 ? (deltaLen > 0 ? deltaLen : state.len) : satAdd32(state.len, deltaLen);
  return { len, seq: satAdd32(state.seq, 1) };
}

const subsliceOk = (off: number, len: number, cap: number) =>
  Number.isInteger(off) && Number.isInteger(len) && Number.isInteger(cap) && off >= 0 && len >= 0 && off <= cap && len <= cap - off;

export function leansysGfmPipeRowAdmitted(
  rowOff: number,
  rowLen: number,
  bufLen: number,
  colCount: number,
  sepCols: number,
  unterminatedEscape: boolean,
): boolean {
  return rowLen > 0 && subsliceOk(rowOff, rowLen, bufLen) && colCount >= 1 && colCount <= 64 && sepCols === colCount && !unterminatedEscape;
}

export function leansysRichTagAdmitted(
  tagOff: number,
  tagLen: number,
  attrOff: number,
  attrLen: number,
  bufLen: number,
  tagKind: number,
): boolean {
  return tagLen > 0 && subsliceOk(tagOff, tagLen, bufLen) && tagOff <= attrOff && subsliceOk(attrOff - tagOff, attrLen, tagLen)
    && tagKind >= 1 && tagKind <= 3;
}
