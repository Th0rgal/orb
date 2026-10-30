import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { listMissionAutomations, getMissionAutomationExecutions } from '@/lib/api';
import { MissionAutomationsDialog } from './mission-automations-dialog';
const { error } = vi.hoisted(() => ({ error: vi.fn() }));
vi.mock('@/components/toast', () => ({ toast: { error, success: vi.fn() } }));
vi.mock('@/lib/api', () => ({
  listMissionAutomations: vi.fn().mockResolvedValue([{
    id: 'a', mission_id: 'm', active: true, command_source: { type: 'inline', content: 'Webhook prompt' },
    trigger: { type: 'webhook', config: { webhook_id: 'hook' } }, created_at: '2026-01-01T00:00:00Z',
  }]),
  getMissionAutomationExecutions: vi.fn().mockResolvedValue([]),
}));
async function openDialog() {
  render(<MissionAutomationsDialog open missionId="m" onClose={vi.fn()} />);
  await screen.findByText('Webhook prompt');
}
describe('webhook URL copy', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(listMissionAutomations).mockResolvedValue([{
      id: 'a', mission_id: 'm', active: true, command_source: { type: 'inline', content: 'Webhook prompt' },
      trigger: { type: 'webhook', config: { webhook_id: 'hook' } }, created_at: '2026-01-01T00:00:00Z',
    }]);
    vi.mocked(getMissionAutomationExecutions).mockResolvedValue([]);
    Object.defineProperty(document, 'execCommand', { configurable: true, value: vi.fn().mockReturnValue(false) });
  });
  afterEach(() => { cleanup(); vi.unstubAllGlobals(); Reflect.deleteProperty(document, 'execCommand'); });
  it.each(['missing', 'denied'])('reports %s clipboard access and allows retry', async (mode) => {
    const writeText = vi.fn().mockRejectedValueOnce(new Error('Not allowed')).mockResolvedValue(undefined);
    vi.stubGlobal('navigator', { clipboard: mode === 'missing' ? undefined : { writeText } });
    await openDialog();
    fireEvent.click(screen.getByRole('button', { name: 'Copy', exact: true }));
    await waitFor(() => expect(error).toHaveBeenCalledWith(expect.stringContaining('Failed to copy webhook URL')));
    expect(screen.queryByText('Copied', { exact: true })).not.toBeInTheDocument();
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } });
    fireEvent.click(screen.getByRole('button', { name: 'Copy', exact: true }));
    await screen.findByText('Copied', { exact: true });
  });
  it('uses the shared fallback when the clipboard API is absent', async () => {
    vi.stubGlobal('navigator', {});
    const execCommand = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, 'execCommand', { configurable: true, value: execCommand });
    try {
      await openDialog();
      fireEvent.click(screen.getByRole('button', { name: 'Copy', exact: true }));
      await screen.findByText('Copied', { exact: true });
      expect(execCommand).toHaveBeenCalledWith('copy');
      expect(error).not.toHaveBeenCalled();
    } finally { Reflect.deleteProperty(document, 'execCommand'); }
  });
});
