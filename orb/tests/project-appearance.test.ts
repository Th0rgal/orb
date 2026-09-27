import { expect, it } from 'vitest';
import { setApiUrl } from '../src/api';
import { projectColor, setProjectColor } from '../src/projectAppearance';
it('persists color by server and project and supports reset', () => {
  setApiUrl('https://first.example');
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
