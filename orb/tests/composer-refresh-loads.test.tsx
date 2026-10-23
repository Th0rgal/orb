import { render } from '@solidjs/testing-library';
import { createSignal } from 'solid-js';
import { expect, it, vi } from 'vitest';
import { Composer } from '../src/composer/Composer';
import { loadAttachItems } from '../src/attach';
import { refreshNodeAntigravityModels } from '../src/harnessPick';
vi.mock('../src/attach', async importOriginal => ({ ...await importOriginal<typeof import('../src/attach')>(), loadAttachItems: vi.fn(async () => []) }));
vi.mock('../src/harnessPick', async importOriginal => ({ ...await importOriginal<typeof import('../src/harnessPick')>(), refreshNodeAntigravityModels: vi.fn(async () => {}) }));
vi.mock('../src/api', async importOriginal => ({ ...await importOriginal<typeof import('../src/api')>(), isConnected: () => true }));

// The conversation view passes props derived from its mission object, which
// every poll replaces. Equal values must not reload project files or catalogs
// (the desktop issued ~0.3 manifest and ~0.4 catalog reads per second).
it('loads attachments and machine catalogs once while the mission is refreshed with equal values', () => {
  const [mission, setMission] = createSignal({ project: 'maxwell', node: 'nippur', rev: 0 });
  render(() => <Composer placeholder="Write" projectSlug={mission().project} uploadTarget={mission().node} busy={false} onSend={() => {}} onStop={() => {}} />);
  for (let rev = 1; rev <= 5; rev++) setMission({ project: 'maxwell', node: 'nippur', rev });
  expect(loadAttachItems).toHaveBeenCalledTimes(1);
  expect(refreshNodeAntigravityModels).toHaveBeenCalledTimes(1);
  setMission({ project: 'other', node: 'ashur', rev: 6 });
  expect(loadAttachItems).toHaveBeenCalledTimes(2);
  expect(refreshNodeAntigravityModels).toHaveBeenLastCalledWith('ashur');
});
