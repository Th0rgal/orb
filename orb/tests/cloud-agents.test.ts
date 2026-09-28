import { describe, expect, it } from 'vitest';
import { cloudCanSend, cloudPhase, safeCloudUrl, type CloudExecution } from '../src/cloudAgentApi';
describe('cloud execution safety', () => {
  it('does not describe a lost connection or uncertain submission as finished', () => {
    expect(cloudPhase('reconnect_required')).toBe('Reconnect account');
    expect(cloudPhase('submission_uncertain')).toBe('Submission needs verification');
    expect(cloudPhase('cancel_requested')).toContain('awaiting confirmation');
    expect(cloudPhase('response_complete')).toBe('Response complete');
  });
  it('blocks a new submission until the previous uncertain turn is reconciled', () => {
    const e = {turns:[{phase:'submission_uncertain'}]} as CloudExecution;
    expect(cloudCanSend(e)).toBe(false);
    e.turns[0].phase = 'response_complete'; expect(cloudCanSend(e)).toBe(true);
  });
  it('never opens script or credential-bearing provider links', () => {
    expect(safeCloudUrl('javascript:alert(1)')).toBeUndefined();
    expect(safeCloudUrl('https://secret@example.com')).toBeUndefined();
    expect(safeCloudUrl('https://cursor.com/agents/bc-1')).toBe('https://cursor.com/agents/bc-1');
  });
});
