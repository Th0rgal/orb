import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MissionAutomationsDialog } from './mission-automations-dialog';
vi.mock('@/components/toast', () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock('@/lib/api', () => ({ listMissionAutomations: vi.fn().mockResolvedValue([]), getMissionAutomationExecutions: vi.fn().mockResolvedValue([]) }));
afterEach(() => { cleanup(); vi.useRealTimers(); });
describe('prompt debounce lifecycle', () => {
  it.each(['close', 'mission', 'unmount'])('cancels pending parsing on %s', async (change) => {
    const view = render(<MissionAutomationsDialog open missionId="m1" onClose={vi.fn()} />);
    await screen.findByText('No automations yet. Create one above.');
    vi.useFakeTimers();
    fireEvent.change(screen.getByPlaceholderText('Enter the prompt to send to the agent. Use <variable_name/> for variables.'), { target: { value: 'Use <stale_variable/>' } });
    expect(vi.getTimerCount()).toBeGreaterThan(0);
    if (change === 'unmount') view.unmount();
    else view.rerender(<MissionAutomationsDialog open={change !== 'close'} missionId={change === 'mission' ? 'm2' : 'm1'} onClose={vi.fn()} />);
    expect(vi.getTimerCount()).toBe(0);
    await act(async () => vi.advanceTimersByTime(400));
    if (change === 'close') view.rerender(<MissionAutomationsDialog open missionId="m1" onClose={vi.fn()} />);
    expect(screen.queryByDisplayValue('stale_variable')).not.toBeInTheDocument();
  });
  it('still parses variables while the same dialog stays open', async () => {
    render(<MissionAutomationsDialog open missionId="m1" onClose={vi.fn()} />);
    await screen.findByText('No automations yet. Create one above.');
    vi.useFakeTimers();
    fireEvent.change(screen.getByPlaceholderText('Enter the prompt to send to the agent. Use <variable_name/> for variables.'), { target: { value: '<expected/>' } });
    act(() => vi.advanceTimersByTime(400));
    expect(screen.getByDisplayValue('expected')).toBeInTheDocument();
  });
});
