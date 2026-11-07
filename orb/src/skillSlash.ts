import { isValidSkillIdentifier, orbSkillSlashStep } from "./orbKernel";

export const MAX_SKILL_NAME = 64;
export const MAX_SELECTED_SKILLS = 8;
const TOKEN = /(^|[\s])\/skill:([^\s]*)/g;

export interface SkillChoice {
  name: string;
  description?: string | null;
}

export interface SkillToken {
  name: string;
  start: number;
  end: number;
}

export function skillToken(name: string): string {
  return `/skill:${name}`;
}

export function skillTokens(text: string): SkillToken[] {
  const out: SkillToken[] = [];
  for (let match = TOKEN.exec(text); match; match = TOKEN.exec(text)) {
    const start = match.index + match[1].length;
    out.push({ name: match[2], start, end: start + match[0].length - match[1].length });
  }
  TOKEN.lastIndex = 0;
  return out;
}

export function skillQuery(text: string, caret: number): { open: boolean; query: string; start: number } {
  const before = text.slice(0, caret);
  const match = /(^|[\s])\/([^\s]*)$/.exec(before);
  if (!match || match[2].includes("/") || match[2].startsWith("skill:")) return { open: false, query: "", start: -1 };
  const start = before.length - match[2].length - 1;
  return { open: true, query: match[2].toLowerCase(), start };
}

export function filterSkills(skills: SkillChoice[], query: string, selected: string[]): SkillChoice[] {
  const used = new Set(selected);
  return skills.filter(skill => !used.has(skill.name) && (!query || skill.name.toLowerCase().includes(query) || (skill.description ?? "").toLowerCase().includes(query))).slice(0, 50);
}

export function insertSkill(text: string, caret: number, name: string): { text: string; caret: number } {
  const query = skillQuery(text, caret);
  const start = query.open && query.start >= 0 ? query.start : caret;
  const token = `${skillToken(name)} `;
  return { text: `${text.slice(0, start)}${token}${text.slice(caret)}`, caret: start + token.length };
}

export function removeSkill(text: string, name: string): string {
  const token = skillTokens(text).find(item => item.name === name);
  if (!token) return text;
  const next = `${text.slice(0, token.start)}${text.slice(token.end)}`;
  return next.replace(/[^\S\n]{2,}/g, " ").replace(/^[^\S\n]+|[^\S\n]+$/g, "");
}

export function selectedSkillNames(text: string, available: ReadonlySet<string>): string[] {
  const names: string[] = [];
  for (const token of skillTokens(text)) {
    if (available.has(token.name) && !names.includes(token.name)) names.push(token.name);
  }
  return names;
}

export function validateSkillSelection(text: string, harness: string | null | undefined, available: ReadonlySet<string>): string | null {
  const kind = harness === "opencode" ? 1 : harness === "claudecode" ? 2 : 0;
  const selected: string[] = [];
  for (const token of skillTokens(text)) {
    if (selected.includes(token.name)) continue;
    const verdict = orbSkillSlashStep({
      harnessKind: kind,
      isDelivered: available.has(token.name),
      alreadySelected: false,
      nameCharsValid: isValidSkillIdentifier(token.name),
      nameLen: token.name.length,
      maxNameLen: MAX_SKILL_NAME,
      selectedCount: selected.length,
      maxSelected: MAX_SELECTED_SKILLS,
    });
    if (!verdict.admitted) {
      if (verdict.rejectCode === 1 || verdict.rejectCode === 2) return "Invalid /skill: identifier (use at most 64 ASCII letters, numbers, '.', '_' or '-', without '..')";
      if (verdict.rejectCode === 3) return `Selected skill is not delivered to this mission: ${token.name}`;
      if (verdict.rejectCode === 5) return "Select at most 8 distinct skills";
      return "Skill selection rejected";
    }
    selected.push(token.name);
  }
  return null;
}

export function skillDisplayText(text: string, available: ReadonlySet<string>): string {
  return skillTokens(text).reduceRight((current, token) => available.has(token.name) ? `${current.slice(0, token.start)}/${token.name}${current.slice(token.end)}` : current, text);
}

export function skillPreview(text: string): string {
  return skillDisplayText(text, new Set(skillTokens(text).map(token => token.name)));
}
