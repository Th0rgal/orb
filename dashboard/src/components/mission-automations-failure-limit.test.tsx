import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createMissionAutomation, listMissionAutomations } from '@/lib/api';
import { MissionAutomationsDialog } from './mission-automations-dialog';

vi.mock('@/contexts/library-context', () => ({
  useLibrary: () => ({ commands: [], loading: false, libraryUnavailable: false }),
}));
vi.mock('@/components/toast', () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock('@/lib/api', () => ({
  listMissionAutomations: vi.fn().mockResolvedValue([]),
  getMissionAutomationExecutions: vi.fn().mockResolvedValue([]),
  createMissionAutomation: vi.fn(),
}));

async function openForm() {
  render(<MissionAutomationsDialog open missionId="mission-1" onClose={vi.fn()} />);
  await waitFor(() => expect(listMissionAutomations).toHaveBeenCalled());
  fireEvent.change(screen.getByRole('option', { name: 'Inline prompt' }).closest('select')!, {
    target: { value: 'inline' },
  });
  fireEvent.change(screen.getByPlaceholderText('Enter the prompt to send to the agent. Use <variable_name/> for variables.'), {
    target: { value: 'Check the build' },
  });
}

describe('automation failure limit', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(createMissionAutomation).mockImplementation(async (_id, input) => ({
      ...input, id: 'automation-1', mission_id: 'mission-1', active: true,
      created_at: '2026-01-01T00:00:00Z',
    }));
  });
  afterEach(cleanup);

  it.each([1, 5, 20])('submits a selected limit of %i and restores the default', async (count) => {
    await openForm();
    expect(screen.getByLabelText('Consecutive failures')).toHaveValue(2);
    fireEvent.change(screen.getByLabelText('Consecutive failures'), { target: { value: String(count) } });
    fireEvent.click(screen.getByRole('button', { name: 'Create automation' }));
    await waitFor(() => expect(createMissionAutomation).toHaveBeenCalledWith('mission-1', expect.objectContaining({
      stop_policy: { type: 'when_failing_consecutively', count },
    })));
    await waitFor(() => expect(screen.getByLabelText('Consecutive failures')).toHaveValue(2));
  });

  it.each(['', '0', '-1', '1.5', '21'])('blocks the invalid limit %j without blocking Never', async (value) => {
    await openForm();
    fireEvent.change(screen.getByLabelText('Consecutive failures'), { target: { value } });
    expect(screen.getByLabelText('Consecutive failures')).toHaveAttribute('aria-invalid', 'true');
    const button = screen.getByRole('button', { name: 'Create automation' });
    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(createMissionAutomation).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('Stop policy'), { target: { value: 'never' } });
    expect(screen.queryByLabelText('Consecutive failures')).not.toBeInTheDocument();
    expect(button).toBeEnabled();
    fireEvent.click(button);
    await waitFor(() => expect(createMissionAutomation).toHaveBeenCalledWith('mission-1', expect.objectContaining({
      stop_policy: { type: 'never' },
    })));
  });
});
