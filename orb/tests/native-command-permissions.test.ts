import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { expect, it } from 'vitest';

// Every native command invoked by the frontend must be explicitly admitted by
// `supportedDesktopCommands` in `lean/OrbLocald/OrbLocald/Rpc.lean`.
it('grants the local agent commands invoked by the frontend', () => {
  const rpcLean = readFileSync(join(process.cwd(), '../lean/OrbLocald/OrbLocald/Rpc.lean'), 'utf8');
  const start = rpcLean.indexOf('def supportedDesktopCommands');
  expect(start).toBeGreaterThanOrEqual(0);
  const block = rpcLean.slice(start, rpcLean.indexOf(']', start) + 1);
  const allowed = new Set([...block.matchAll(/"([a-z_]+)"/g)].map(m => m[1]));
  const source = readFileSync(join(process.cwd(), 'src/localAgents.ts'), 'utf8');
  const commands = [...source.matchAll(/\binvoke\s*\(\s*['"]([^'"]+)['"]/g)].map(m => m[1]);
  expect(commands.length).toBeGreaterThan(0);
  expect(commands.filter(command => !allowed.has(command))).toEqual([]);
});
