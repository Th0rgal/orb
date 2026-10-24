import { cleanup, render, screen } from '@testing-library/react';
import { SWRConfig } from 'swr';
import { afterEach, describe, expect, it, vi } from 'vitest';

import BackendsPage from './page';

const { refreshBackendConfigs, backendConfigsFixture } = vi.hoisted(() => ({
  refreshBackendConfigs: vi.fn(),
  backendConfigsFixture: {
    opencode: {
      enabled: true,
      settings: { base_url: 'http://127.0.0.1:4096' },
    },
    claudecode: { enabled: true, settings: {} },
    grok: { enabled: false, settings: {} },
  },
}));

vi.mock('@/components/server-connection-card', () => ({
  ServerConnectionCard: () => <div>Server connection</div>,
}));

vi.mock('@/components/model-routing-debug', () => ({
  ModelRoutingDebug: () => <div>Model routing</div>,
}));

vi.mock('@/components/toast', () => ({
  toast: {
    success: vi.fn(),
    error: vi.fn(),
  },
}));

vi.mock('@/lib/api', () => ({
  listBackends: vi.fn().mockResolvedValue([
    { id: 'opencode', name: 'OpenCode' },
    { id: 'codex', name: 'Codex' },
  ]),
  updateBackendConfig: vi.fn().mockResolvedValue({ message: 'saved' }),
  getProviderForBackend: vi.fn().mockResolvedValue({ configured: false }),
  getHealth: vi.fn().mockResolvedValue({ version: '1.3.0' }),
  getSettings: vi.fn().mockResolvedValue({
    max_parallel_missions: 1,
    max_concurrent_tasks: 5,
  }),
  updateSettings: vi.fn().mockResolvedValue({}),
}));

vi.mock('@/lib/use-backend-configs', () => ({
  useBackendConfigs: () => ({
    configs: backendConfigsFixture,
    refresh: refreshBackendConfigs,
  }),
}));


function renderPage() {
  return render(
    <SWRConfig value={{ provider: () => new Map(), dedupingInterval: 0 }}>
      <BackendsPage />
    </SWRConfig>
  );
}

describe('BackendsPage', () => {
  afterEach(() => {
    cleanup();
  });

  it('offers only the supported configurable backends', async () => {
    renderPage();

    expect(await screen.findByRole('button', { name: 'OpenCode' })).toBeVisible();
    expect(screen.getByRole('button', { name: 'Claude Code' })).toBeVisible();
    expect(screen.getByRole('button', { name: 'Grok Build' })).toBeVisible();
    expect(screen.queryByRole('button', { name: /ChatGPT UI/ })).toBeNull();
  });
});
