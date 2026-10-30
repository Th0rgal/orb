import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { SWRConfig } from 'swr';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { deleteAutomation, listActiveAutomations, updateAutomation } from '@/lib/api';
import { ActiveAutomations } from './active-automations';

const { showError } = vi.hoisted(() => ({ showError: vi.fn() }));
vi.mock('@/components/toast', () => ({ useToast: () => ({ showError }) }));
vi.mock('@/lib/api', () => ({
  listActiveAutomations: vi.fn(),
  getMission: vi.fn().mockResolvedValue(null),
  updateAutomation: vi.fn(),
  deleteAutomation: vi.fn(),
}));

const automation = {
  id: 'automation-1', mission_id: 'mission-1', active: true,
  command_source: { type: 'inline' as const, content: 'Check the build' },
  trigger: { type: 'interval' as const, seconds: 60 }, created_at: '2026-01-01T00:00:00Z',
};

async function openPanel() {
  render(<SWRConfig value={{ provider: () => new Map(), dedupingInterval: 0 }}>
    <ActiveAutomations missions={[]} runningMissionIds={new Set()} />
  </SWRConfig>);
  await screen.findByText('Check the build');
}

describe('active automation action failures', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(listActiveAutomations).mockResolvedValue([automation]);
    vi.mocked(updateAutomation).mockResolvedValue(automation);
    vi.mocked(deleteAutomation).mockResolvedValue(undefined);
  });
  afterEach(cleanup);

  it.each([new Error('Permission denied'), 'unexpected response'])('reports disable failure and allows retry: %s', async (error) => {
    vi.mocked(updateAutomation).mockRejectedValueOnce(error);
    await openPanel();
    const button = screen.getByTitle('Disable (keeps the row, stops firing)');
    const fetches = vi.mocked(listActiveAutomations).mock.calls.length;
    fireEvent.click(button);
    await waitFor(() => expect(showError).toHaveBeenCalledWith(error instanceof Error ? error.message : 'Failed to disable automation'));
    expect(button).toBeEnabled();
    expect(screen.getByText('Check the build')).toBeInTheDocument();
    expect(listActiveAutomations).toHaveBeenCalledTimes(fetches);
    fireEvent.click(button);
    await waitFor(() => expect(updateAutomation).toHaveBeenCalledTimes(2));
    expect(updateAutomation).toHaveBeenLastCalledWith('automation-1', { active: false });
    await waitFor(() => expect(vi.mocked(listActiveAutomations).mock.calls.length).toBeGreaterThan(fetches));
  });

  it.each([new Error('Server unavailable'), null])('keeps failed removal confirmed and allows retry: %s', async (error) => {
    vi.mocked(deleteAutomation).mockRejectedValueOnce(error);
    await openPanel();
    fireEvent.click(screen.getByTitle('Remove permanently'));
    const fetches = vi.mocked(listActiveAutomations).mock.calls.length;
    fireEvent.click(screen.getByRole('button', { name: 'Remove', exact: true }));
    await waitFor(() => expect(showError).toHaveBeenCalledWith(error instanceof Error ? error.message : 'Failed to remove automation'));
    const retry = screen.getByRole('button', { name: 'Remove', exact: true });
    expect(retry).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeEnabled();
    expect(screen.getByText('Check the build')).toBeInTheDocument();
    expect(listActiveAutomations).toHaveBeenCalledTimes(fetches);
    fireEvent.click(retry);
    await waitFor(() => expect(deleteAutomation).toHaveBeenCalledTimes(2));
    expect(deleteAutomation).toHaveBeenLastCalledWith('automation-1');
    await waitFor(() => expect(screen.getByTitle('Remove permanently')).toBeEnabled());
    await waitFor(() => expect(vi.mocked(listActiveAutomations).mock.calls.length).toBeGreaterThan(fetches));
  });
});
