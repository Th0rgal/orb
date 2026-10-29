import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { SWRConfig } from 'swr';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getClaudeCodeHostConfig, getConfigProfileFile, saveConfigProfileFile } from '@/lib/api';
import SettingsPage from './page';

vi.mock('@/components/config-code-editor', () => ({
  ConfigCodeEditor: ({ value, onChange }: { value: string; onChange: (value: string) => void }) => (
    <textarea aria-label="Settings JSON" value={value} onChange={(event) => onChange(event.target.value)} />
  ),
}));

vi.mock('@/contexts/library-context', () => ({
  useLibrary: () => ({
    status: { branch: 'main', clean: true, ahead: 0, behind: 0 },
    refreshStatus: vi.fn().mockResolvedValue(undefined),
  }),
}));

vi.mock('@/lib/api', () => ({
  getBackendConfig: vi.fn().mockResolvedValue({ enabled: true }),
  listConfigProfiles: vi.fn().mockResolvedValue([{ name: 'default', is_default: true }]),
  listConfigProfileFiles: vi.fn().mockResolvedValue(['.claudecode/settings.json']),
  getConfigProfileFile: vi.fn(),
  saveConfigProfileFile: vi.fn().mockResolvedValue(undefined),
  getOpenCodeConfig: vi.fn().mockResolvedValue({}),
  updateOpenCodeConfig: vi.fn(),
  getClaudeCodeHostConfig: vi.fn(),
  updateClaudeCodeHostConfig: vi.fn(),
}));

const preferences = { default_model: 'claude-opus-5', default_agent: null, hidden_agents: [] };
const nativeSettings = {
  hooks: { Stop: [{ hooks: [{ type: 'command', command: 'echo finished' }] }] },
  env: { TRACE_ENABLED: '1' },
  permissions: { deny: ['Read(.env)'] },
  attribution: { commit: '', pr: '' },
  futureSetting: { enabled: false, entries: ['one', 'two'] },
};

async function openClaudeSettings() {
  render(<SWRConfig value={{ provider: () => new Map(), dedupingInterval: 0 }}><SettingsPage /></SWRConfig>);
  fireEvent.click(await screen.findByRole('button', { name: 'Claude Code' }));
  await waitFor(() => expect(getConfigProfileFile).toHaveBeenCalledWith('default', '.claudecode/settings.json'));
  await waitFor(() => expect(screen.getByLabelText('Settings JSON')).toHaveValue(JSON.stringify(preferences)));
  await screen.findByRole('button', { name: 'Pull from Host' });
}

async function savedSettings() {
  await waitFor(() => expect(saveConfigProfileFile).toHaveBeenCalledTimes(1));
  const [profile, path, content] = vi.mocked(saveConfigProfileFile).mock.calls[0];
  expect([profile, path]).toEqual(['default', '.claudecode/settings.json']);
  return JSON.parse(content);
}

describe('Claude profile settings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(getConfigProfileFile).mockResolvedValue(JSON.stringify(preferences));
    vi.mocked(getClaudeCodeHostConfig).mockResolvedValue(preferences);
    vi.stubGlobal('confirm', vi.fn().mockReturnValue(true));
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('preserves native settings when saving the default profile', async () => {
    await openClaudeSettings();
    const edited = { ...preferences, default_model: 'custom-model', ...nativeSettings };
    fireEvent.change(screen.getByLabelText('Settings JSON'), { target: { value: JSON.stringify(edited) } });
    fireEvent.click(screen.getByRole('button', { name: 'Save', exact: true }));
    expect(await savedSettings()).toEqual(edited);
  });

  it('preserves native settings while normalizing dashboard preferences', async () => {
    await openClaudeSettings();
    fireEvent.change(screen.getByLabelText('Settings JSON'), {
      target: { value: JSON.stringify({ ...nativeSettings, default_model: 'claude-opus-4.8', default_agent: 42, hidden_agents: ['hidden', false] }) },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save', exact: true }));
    expect(await savedSettings()).toEqual({ ...nativeSettings, ...preferences, hidden_agents: ['hidden'] });
  });

  it('preserves native settings when pulling from the host', async () => {
    const host = { ...preferences, ...nativeSettings };
    vi.mocked(getClaudeCodeHostConfig).mockResolvedValue(host);
    await openClaudeSettings();
    fireEvent.click(screen.getByRole('button', { name: 'Pull from Host' }));
    expect(await savedSettings()).toEqual(host);
    expect(JSON.parse((screen.getByLabelText('Settings JSON') as HTMLTextAreaElement).value)).toEqual(host);
  });

  it('detects differences in native settings instead of claiming the host matches', async () => {
    vi.mocked(getClaudeCodeHostConfig).mockResolvedValue({ ...preferences, ...nativeSettings });
    await openClaudeSettings();
    expect(screen.getByText('Host differs')).toBeVisible();
    expect(screen.queryByText('Host matches')).not.toBeInTheDocument();
  });
});
