import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getAutomationExecutions, listMissionAutomations, type AutomationExecution } from '@/lib/api';
import { MissionAutomationsDialog } from './mission-automations-dialog';
vi.mock('@/components/toast', () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock('@/lib/api', () => ({
  listMissionAutomations: vi.fn(), getMissionAutomationExecutions: vi.fn().mockResolvedValue([]),
  getAutomationExecutions: vi.fn(),
}));
const rows = ['A', 'B'].map((id) => ({ id, mission_id: 'mission-1', active: true,
  command_source: { type: 'inline' as const, content: `Prompt ${id}` },
  trigger: { type: 'interval' as const, seconds: 60 }, created_at: '2026-01-01T00:00:00Z',
}));
function deferred() {
  let resolve!: (value: AutomationExecution[]) => void;
  const promise = new Promise<AutomationExecution[]>((done) => { resolve = done; });
  return { promise, resolve };
}
function execution(id: string): AutomationExecution[] {
  return [{ id, automation_id: id, mission_id: 'mission-1', triggered_at: '2026-01-01T00:00:00Z',
    trigger_source: 'interval', status: 'failed', variables_used: {}, retry_count: 0, error: `History ${id}` }];
}
async function openDialog() {
  const view = render(<MissionAutomationsDialog open missionId="mission-1" onClose={vi.fn()} />);
  await screen.findByText('Prompt A');
  return view;
}
describe('automation execution history', () => {
  beforeEach(() => { vi.clearAllMocks(); vi.mocked(listMissionAutomations).mockResolvedValue(rows); });
  afterEach(cleanup);
  it('ignores a previous row response while the current row is loading', async () => {
    const a = deferred(); const b = deferred();
    vi.mocked(getAutomationExecutions).mockReturnValueOnce(a.promise).mockReturnValueOnce(b.promise);
    await openDialog();
    const buttons = screen.getAllByTitle('Execution history');
    fireEvent.click(buttons[0]); fireEvent.click(buttons[1]);
    await act(async () => a.resolve(execution('A')));
    expect(screen.getByText('Loading executions...')).toBeInTheDocument();
    expect(screen.queryByText('History A')).not.toBeInTheDocument();
    await act(async () => b.resolve(execution('B')));
    expect(screen.getByText('History B')).toBeInTheDocument();
  });
  it('does not overwrite newer history when a stale request resolves last', async () => {
    const a = deferred(); const b = deferred();
    vi.mocked(getAutomationExecutions).mockReturnValueOnce(a.promise).mockReturnValueOnce(b.promise);
    await openDialog();
    const buttons = screen.getAllByTitle('Execution history');
    fireEvent.click(buttons[0]); fireEvent.click(buttons[1]);
    await act(async () => b.resolve(execution('B')));
    await act(async () => a.resolve(execution('A')));
    expect(screen.getByText('History B')).toBeInTheDocument();
    expect(screen.queryByText('History A')).not.toBeInTheDocument();
  });
  it('shows failed requests as errors and allows retrying an empty history', async () => {
    vi.mocked(getAutomationExecutions).mockRejectedValueOnce(new Error('History unavailable')).mockResolvedValueOnce([]);
    await openDialog(); fireEvent.click(screen.getAllByTitle('Execution history')[0]);
    expect(await screen.findByRole('alert')).toHaveTextContent('History unavailable');
    expect(screen.queryByText('No executions recorded yet.')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry execution history' }));
    await screen.findByText('No executions recorded yet.');
    expect(getAutomationExecutions).toHaveBeenNthCalledWith(2, 'A');
  });
  it('invalidates pending history on close and reopen', async () => {
    const old = deferred();
    vi.mocked(getAutomationExecutions).mockReturnValueOnce(old.promise).mockResolvedValueOnce([]);
    const view = await openDialog(); fireEvent.click(screen.getAllByTitle('Execution history')[0]);
    view.rerender(<MissionAutomationsDialog open={false} missionId="mission-1" onClose={vi.fn()} />);
    view.rerender(<MissionAutomationsDialog open missionId="mission-1" onClose={vi.fn()} />);
    fireEvent.click(screen.getAllByTitle('Execution history')[0]);
    await screen.findByText('No executions recorded yet.');
    await act(async () => old.resolve(execution('A')));
    expect(screen.queryByText('History A')).not.toBeInTheDocument();
    await waitFor(() => expect(screen.getByText('No executions recorded yet.')).toBeInTheDocument());
  });
});
