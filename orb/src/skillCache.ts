// Per-session cache of the local skills report: reopening Skills shows it at once,
// and a skill page reads its own row (edited copy, old copy) without rescanning.
import type { LocalSkillsReport } from "./localAgents";

let report: LocalSkillsReport | null = null;
export const cachedSkillsReport = () => report;
export const rememberSkillsReport = (next: LocalSkillsReport) => { report = next; };
export const cachedSkill = (name: string) => report?.skills.find((s) => s.name === name) ?? null;
