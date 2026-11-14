// Per-session cache of the local skills report: reopening Skills shows it at once,
// and a skill page reads its own row (edited copy, old copy) without rescanning.
import { connectionVersion } from "./api";
import type { LocalSkillsReport } from "./localAgents";

let report: LocalSkillsReport | null = null;
let reportVersion = -1;
export const cachedSkillsReport = () => reportVersion === connectionVersion() ? report : null;
export const rememberSkillsReport = (next: LocalSkillsReport) => { report = next; reportVersion = connectionVersion(); };
export const cachedSkill = (name: string) => cachedSkillsReport()?.skills.find((s) => s.name === name) ?? null;
