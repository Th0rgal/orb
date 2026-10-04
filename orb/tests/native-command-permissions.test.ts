import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { expect, it } from 'vitest';

// A registered native command still fails at runtime unless the main window's
// capability grants it. Catch new frontend calls missing that second step.
it('grants the local agent commands invoked by the frontend', () => {
  const native = join(process.cwd(), 'src-tauri');
  const capability = JSON.parse(readFileSync(join(native, 'capabilities/default.json'), 'utf8'));
  const permissions = readdirSync(join(native, 'permissions'))
    .filter(name => name.endsWith('.toml'))
    .map(name => readFileSync(join(native, 'permissions', name), 'utf8'))
    .filter(text => capability.permissions.includes(text.match(/identifier\s*=\s*"([^"]+)"/)?.[1]))
    .map(text => text.match(/commands\.allow\s*=\s*\[([\s\S]*?)\]/)?.[1] ?? '')
    .join('\n');
  const allowed = new Set([...permissions.matchAll(/"([a-z_]+)"/g)].map(m => m[1]));
  const source = readFileSync(join(process.cwd(), 'src/localAgents.ts'), 'utf8');
  const commands = [...source.matchAll(/\binvoke\s*\(\s*['"]([^'"]+)['"]/g)].map(m => m[1]);
  expect(commands.length).toBeGreaterThan(0);
  expect(commands.filter(command => !allowed.has(command))).toEqual([]);
});
