// Host input encoding and presentation over generated scalar ABI adapters.
import { kernelAbi as kernel } from "./orbKernelAbi";

export type WorkfoldVerdict = { foldItem: boolean; foldHasToolNext: boolean };
export type TranscriptPatchState = { len: number; seq: number };
const b8 = (value: boolean) => value ? 1 : 0;
const enum8 = (value: number) => Number.isInteger(value) && value >= 0 && value <= 255 ? value : 255;
const sat8 = (value: number) => Math.max(0, Math.min(255, Number.isFinite(value) ? Math.round(value) : 255));
function seconds(value: number): bigint {
  const whole = Math.max(0, Math.floor(value));
  if (!Number.isSafeInteger(whole)) throw new RangeError("Time is outside the exact integer range");
  return BigInt(whole);
}
const byte = (raw: bigint, shift: bigint) => Number((raw >> shift) & 255n);

export function orbWorkfoldStep(itemKind: number, isCumulative: boolean, isNonEmpty: boolean, toolAhead: boolean,
  nextIsTool: boolean, foldHasTool: boolean): WorkfoldVerdict {
  const raw = kernel.orb_workfold_step(enum8(itemKind), b8(isCumulative), b8(isNonEmpty), b8(toolAhead), b8(nextIsTool), b8(foldHasTool));
  return { foldItem: (raw & 1) !== 0, foldHasToolNext: ((raw >> 8) & 1) !== 0 };
}

export function orbTaskcardStep(turnEnded: boolean, allClosed: boolean, turnOutcomeFinished: boolean): "live" | "done" | "stale" | "stopped" {
  const code = kernel.orb_taskcard_step(b8(turnEnded), b8(allClosed), b8(turnOutcomeFinished));
  return (["live", "done", "stale", "stopped"] as const)[code];
}

export function orbRelativeTimeString(elapsedSecs: number): string {
  const raw = kernel.orb_relative_time_bucket(seconds(elapsedSecs));
  const unit = byte(raw, 0n), value = Number((raw >> 8n) & 0xffff_ffffn);
  return unit === 0 ? "now" : `${value}${["", "m", "h", "d", "w"][unit]}`;
}

export function orbUsageLimitBadge(status: string, claim: string, hasUtilization: boolean, utilizationPct: number,
  hasReset: boolean, resetRemSecs: number): { tone: "warning" | "error"; label: string } | null {
  const statusKind = !status || status === "allowed" || status === "ok" ? 0 : status === "allowed_warning" ? 1 : status === "rejected" ? 2 : 3;
  const claimKind = ["", "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].indexOf(claim);
  const raw = kernel.orb_usage_limit_status(statusKind, Math.max(0, claimKind),
    b8(hasUtilization && Number.isFinite(utilizationPct) && utilizationPct >= 0), sat8(utilizationPct), b8(hasReset), seconds(resetRemSecs));
  const tone = byte(raw, 0n);
  if (tone === 0) return null;
  if (tone === 1) {
    const label = ["", "5h", "weekly", "weekly Opus", "weekly Sonnet"][byte(raw, 8n)];
    const pct = byte(raw, 16n) ? ` ${byte(raw, 24n)}%` : "";
    return { tone: "warning", label: label ? `Approaching limit · ${label}${pct}` : "Approaching limit" };
  }
  if (tone === 2) {
    const unit = byte(raw, 32n), value = Number((raw >> 40n) & 0xff_ffffn);
    return { tone: "error", label: unit ? `Limit reached · resets in ${value}${["", "m", "h", "d"][unit]}` : "Limit reached" };
  }
  return { tone: "warning", label: "Limit status unknown" };
}

export function orbTranscriptPatchStep(state: TranscriptPatchState, eventKind: number, deltaLen: number): TranscriptPatchState {
  const raw = kernel.orb_transcript_patch_step(state.len, state.seq, enum8(eventKind), deltaLen);
  return { len: Number(raw & 0xffff_ffffn), seq: Number(raw >> 32n) };
}

// Coordinates must be exactly representable before crossing the UInt64 boundary.
const coordinates = (...values: number[]) => values.every(value => Number.isSafeInteger(value) && value >= 0);
export function leansysGfmPipeRowAdmitted(rowOff: number, rowLen: number, bufLen: number, colCount: number,
  sepCols: number, unterminatedEscape: boolean): boolean {
  if (!coordinates(rowOff, rowLen, bufLen, colCount, sepCols) || colCount > 0xffff_ffff || sepCols > 0xffff_ffff) return false;
  return kernel.leansys_gfm_pipe_scan(BigInt(rowOff), BigInt(rowLen), BigInt(bufLen), colCount, sepCols, b8(unterminatedEscape)) !== 0;
}

export function leansysRichTagAdmitted(tagOff: number, tagLen: number, attrOff: number, attrLen: number,
  bufLen: number, tagKind: number): boolean {
  if (!coordinates(tagOff, tagLen, attrOff, attrLen, bufLen, tagKind) || tagKind > 255) return false;
  return kernel.leansys_tag_scan(BigInt(tagOff), BigInt(tagLen), BigInt(attrOff), BigInt(attrLen), BigInt(bufLen), tagKind) !== 0;
}
