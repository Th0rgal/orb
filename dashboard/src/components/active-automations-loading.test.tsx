import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { SWRConfig, useSWRConfig } from 'swr';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { listActiveAutomations } from '@/lib/api';
import { ActiveAutomations } from './active-automations';
vi.mock('@/components/toast', () => ({ useToast: () => ({ showError: vi.fn() }) }));
vi.mock('@/lib/api', () => ({ listActiveAutomations: vi.fn(), getMission: vi.fn().mockResolvedValue(null) }));
const row = { id: 'a', mission_id: 'm', active: true,
  command_source: { type: 'inline' as const, content: 'Keep this automation' },
  trigger: { type: 'interval' as const, seconds: 60 }, created_at: '2026-01-01T00:00:00Z' };
function Panel() {
  const { mutate } = useSWRConfig();
  return <><button onClick={() => void mutate('active-automations')}>Refresh fixture</button><ActiveAutomations missions={[]} runningMissionIds={new Set()} /></>;
}
function openPanel() {
  render(<SWRConfig value={{ provider: () => new Map(), dedupingInterval: 0, shouldRetryOnError: false }}><Panel /></SWRConfig>);
}
describe('active automations loading errors', () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(cleanup);
  it('shows a failed initial fetch and retries successfully', async () => {
    vi.mocked(listActiveAutomations).mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce([row]);
    openPanel();
    await screen.findByRole('alert');
    expect(screen.queryByText('No active automations.')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry loading automations' }));
    await screen.findByText('Keep this automation');
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
  });
  it('keeps existing rows when a refresh fails and clears the error on retry', async () => {
    vi.mocked(listActiveAutomations).mockResolvedValueOnce([row]).mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce([row]);
    openPanel(); await screen.findByText('Keep this automation');
    fireEvent.click(screen.getByRole('button', { name: 'Refresh fixture' }));
    await screen.findByRole('alert');
    expect(screen.getByText('Keep this automation')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry loading automations' }));
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
  });
  it('shows the empty state only after a successful empty response', async () => {
    vi.mocked(listActiveAutomations).mockResolvedValue([]);
    openPanel(); await screen.findByText('No active automations.');
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
