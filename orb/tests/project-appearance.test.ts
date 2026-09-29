import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { listProjects, setApiUrl } from '../src/api';
import { applyProjectRoster, projectColor, resetProjectAppearanceSync, setProjectColor } from '../src/projectAppearance';

type Call = { url: string; method: string; body: unknown };
let calls: Call[] = [];
/** Answers every request; `appearance` decides what a color write gets back. */
function backend(options: { roster?: unknown[]; appearance?: () => Response } = {}) {
  calls = [];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input), method = init?.method ?? 'GET';
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (method === 'POST' && url.endsWith('/appearance')) return options.appearance?.() ?? Response.json({ ok: true });
    if (url.endsWith('/api/projects')) return Response.json({ projects: options.roster ?? [] });
    return new Response('not found', { status: 404 });
  }));
}
const writes = () => calls.filter(call => call.method === 'POST');
const settle = () => new Promise(resolve => setTimeout(resolve, 0));
const row = (slug: string, color?: string | null) => ({ slug, status: 'active', updated_at: 'x', ...(color === undefined ? {} : { color }) });
const later = () => Date.now() + 1000;

beforeEach(() => { resetProjectAppearanceSync(); setApiUrl('https://first.example'); backend(); });
afterEach(() => { vi.unstubAllGlobals(); });

it('persists color by server and project and supports reset', () => {
  setProjectColor('project', '#8aaed4');
  expect(projectColor('project')).toBe('#8aaed4');
  expect(projectColor('another')).toBeUndefined();
  setApiUrl('https://second.example');
  expect(projectColor('project')).toBeUndefined();
  setApiUrl('https://first.example');
  expect(projectColor('project')).toBe('#8aaed4');
  setProjectColor('project', 'invalid');
  expect(projectColor('project')).toBe('#8aaed4');
  setProjectColor('project', '');
  expect(projectColor('project')).toBeUndefined();
});

it('writes a change to the server by palette name, and a reset as null', async () => {
  setProjectColor('my project', '#94b89a');
  await settle();
  setProjectColor('my project', '');
  await settle();
  expect(writes()).toEqual([
    { url: 'https://first.example/api/projects/my%20project/appearance', method: 'POST', body: { color: 'green' } },
    { url: 'https://first.example/api/projects/my%20project/appearance', method: 'POST', body: { color: null } },
  ]);
});

it('shows the server color over the local one', async () => {
  localStorage.setItem('orb.projectColor:https://first.example:project', '#8aaed4');
  localStorage.setItem('orb.projectColorSync:https://first.example:project', '1');
  await applyProjectRoster([row('project', 'rose'), row('other', 'purple')], later());
  expect(projectColor('project')).toBe('#cb929f');
  expect(projectColor('other')).toBe('#ad9acb');
  expect(writes()).toEqual([]);
});

it('takes the server color from the project list', async () => {
  backend({ roster: [row('project', 'amber')] });
  await listProjects();
  expect(projectColor('project')).toBe('#c5aa70');
});

it('uploads a color chosen before the server stored any, once', async () => {
  localStorage.setItem('orb.projectColor:https://first.example:project', '#8aaed4');
  await applyProjectRoster([row('project', null)], later());
  expect(projectColor('project')).toBe('#8aaed4');
  expect(writes().map(call => call.body)).toEqual([{ color: 'blue' }]);
  // Another device cleared it afterwards: the server's "none" now wins.
  await applyProjectRoster([row('project', null)], later());
  expect(projectColor('project')).toBeUndefined();
  expect(writes()).toHaveLength(1);
});

it('does not upload over a color the server already has', async () => {
  localStorage.setItem('orb.projectColor:https://first.example:project', '#8aaed4');
  await applyProjectRoster([row('project', 'green')], later());
  expect(projectColor('project')).toBe('#94b89a');
  expect(writes()).toEqual([]);
});

it('keeps the local color on a backend without the field', async () => {
  localStorage.setItem('orb.projectColor:https://first.example:project', '#8aaed4');
  await applyProjectRoster([row('project')], later());
  expect(projectColor('project')).toBe('#8aaed4');
  setProjectColor('project', '#ad9acb');
  await settle();
  expect(projectColor('project')).toBe('#ad9acb');
  expect(writes()).toEqual([]);
});

it('keeps the local color when the backend has no appearance endpoint', async () => {
  backend({ appearance: () => new Response('Not Found', { status: 404 }) });
  setProjectColor('project', '#8aaed4');
  await settle();
  expect(projectColor('project')).toBe('#8aaed4');
  expect(writes()).toHaveLength(1);
});

it('sends a change that failed again with the next project list', async () => {
  let up = false;
  backend({ appearance: () => up ? Response.json({ ok: true }) : new Response('down', { status: 502 }) });
  setProjectColor('project', '#8aaed4');
  await settle();
  up = true;
  // The server still has the old color: the unsent local change is not lost.
  await applyProjectRoster([row('project', 'rose')], later());
  expect(projectColor('project')).toBe('#8aaed4');
  expect(writes().map(call => call.body)).toEqual([{ color: 'blue' }, { color: 'blue' }]);
  await applyProjectRoster([row('project', 'blue')], later());
  expect(writes()).toHaveLength(2);
});

it('ignores a project list requested before the change', async () => {
  const before = Date.now() - 1000;
  setProjectColor('project', '#8aaed4');
  await settle();
  await applyProjectRoster([row('project', 'rose')], before);
  expect(projectColor('project')).toBe('#8aaed4');
});

it('leaves the color alone when the server names one this build does not know', async () => {
  localStorage.setItem('orb.projectColor:https://first.example:project', '#8aaed4');
  await applyProjectRoster([row('project', 'teal')], later());
  expect(projectColor('project')).toBe('#8aaed4');
  expect(writes()).toEqual([]);
});

it('says colors are synced only once the backend is seen storing them', async () => {
  const { projectColorsSynced } = await import('../src/projectAppearance');
  expect(projectColorsSynced()).toBe(false);
  await applyProjectRoster([row('project')], later());
  expect(projectColorsSynced()).toBe(false);
  await applyProjectRoster([row('project', null)], later());
  expect(projectColorsSynced()).toBe(true);
  setApiUrl('https://second.example');
  expect(projectColorsSynced()).toBe(false);
});
