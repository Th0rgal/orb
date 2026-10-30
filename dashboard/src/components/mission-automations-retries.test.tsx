import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createMissionAutomation, listMissionAutomations } from '@/lib/api';
import { MissionAutomationsDialog } from './mission-automations-dialog';

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

describe('automation delivery retries', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(createMissionAutomation).mockImplementation(async (_id, input) => ({
      ...input, id: 'automation-1', mission_id: 'mission-1', active: true,
      created_at: '2026-01-01T00:00:00Z',
    }));
  });
  afterEach(cleanup);


  it('keeps server defaults unless customization is selected', async () => {
    await openForm();
    fireEvent.click(screen.getByRole('button', { name: 'Create automation' }));
    await waitFor(() => expect(createMissionAutomation).toHaveBeenCalled());
    expect(vi.mocked(createMissionAutomation).mock.calls[0][1]).not.toHaveProperty('retry_config');
  });

  it('submits custom retries and resets after creation', async () => {
    await openForm();
    fireEvent.click(screen.getByLabelText('Customize message delivery retries'));
    fireEvent.change(screen.getByLabelText('Maximum delivery retries'), { target: { value: '5' } });
    fireEvent.change(screen.getByLabelText('Initial retry delay (seconds)'), { target: { value: '30' } });
    fireEvent.change(screen.getByLabelText('Retry backoff multiplier'), { target: { value: '1.5' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create automation' }));
    await waitFor(() => expect(createMissionAutomation).toHaveBeenCalledWith('mission-1', expect.objectContaining({
      retry_config: { max_retries: 5, retry_delay_seconds: 30, backoff_multiplier: 1.5 },
    })));
    await waitFor(() => expect(screen.getByLabelText('Customize message delivery retries')).not.toBeChecked());
    fireEvent.click(screen.getByLabelText('Customize message delivery retries'));
    expect(screen.getByLabelText('Maximum delivery retries')).toHaveValue(3);
    expect(screen.getByLabelText('Initial retry delay (seconds)')).toHaveValue(60);
    expect(screen.getByLabelText('Retry backoff multiplier')).toHaveValue(2);
  });

  it.each([
    ['Maximum delivery retries', ''], ['Maximum delivery retries', '-1'], ['Maximum delivery retries', '1.5'], ['Maximum delivery retries', '11'],
    ['Initial retry delay (seconds)', ''], ['Initial retry delay (seconds)', '0'], ['Initial retry delay (seconds)', '3601'],
    ['Retry backoff multiplier', ''], ['Retry backoff multiplier', '0.5'], ['Retry backoff multiplier', '6'],
  ])('blocks invalid %s %j only when customization is enabled', async (label, value) => {
    await openForm();
    fireEvent.click(screen.getByLabelText('Customize message delivery retries'));
    fireEvent.change(screen.getByLabelText(label), { target: { value } });
    expect(screen.getByLabelText(label)).toHaveAttribute('aria-invalid', 'true');
    const button = screen.getByRole('button', { name: 'Create automation' });
    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(createMissionAutomation).not.toHaveBeenCalled();
    fireEvent.click(screen.getByLabelText('Customize message delivery retries'));
    expect(button).toBeEnabled();
  });

  it('allows disabling retries despite invalid hidden delay values', async () => {
    await openForm();
    fireEvent.click(screen.getByLabelText('Customize message delivery retries'));
    fireEvent.change(screen.getByLabelText('Initial retry delay (seconds)'), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText('Maximum delivery retries'), { target: { value: '0' } });
    expect(screen.queryByLabelText('Initial retry delay (seconds)')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Create automation' }));
    await waitFor(() => expect(createMissionAutomation).toHaveBeenCalledWith('mission-1', expect.objectContaining({
      retry_config: { max_retries: 0, retry_delay_seconds: 60, backoff_multiplier: 2 },
    })));
  });
});
