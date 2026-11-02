import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ConfirmDialog } from './confirm-dialog';
afterEach(cleanup);
describe('confirmation pending state', () => {
  it('blocks every dismissal while async confirmation is pending and restores cancellation afterward', async () => {
    let resolve!: () => void;
    const onConfirm = vi.fn(() => new Promise<void>((done) => { resolve = done; }));
    const onCancel = vi.fn();
    render(<ConfirmDialog open title="Delete fixture" description="Fixture description" onConfirm={onConfirm} onCancel={onCancel} />);
    const confirm = screen.getByRole('button', { name: 'Confirm' });
    fireEvent.click(confirm);
    expect(confirm).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    for (const button of screen.getAllByRole('button')) fireEvent.click(button);
    fireEvent.keyDown(document, { key: 'Escape' }); fireEvent.mouseDown(document.body);
    expect(onCancel).not.toHaveBeenCalled(); expect(onConfirm).toHaveBeenCalledTimes(1);
    await act(async () => resolve());
    expect(confirm).toBeEnabled();
    fireEvent.keyDown(document, { key: 'Escape' }); expect(onCancel).toHaveBeenCalledTimes(1);
    fireEvent.mouseDown(document.body); expect(onCancel).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' })); expect(onCancel).toHaveBeenCalledTimes(3);
  });
  it('continues to respect an external busy flag', () => {
    const onConfirm = vi.fn(); const onCancel = vi.fn();
    render(<ConfirmDialog open busy title="Fixture" description="Fixture" onConfirm={onConfirm} onCancel={onCancel} />);
    fireEvent.keyDown(document, { key: 'Escape' }); fireEvent.mouseDown(document.body);
    for (const button of screen.getAllByRole('button')) { expect(button).toBeDisabled(); fireEvent.click(button); }
    expect(onCancel).not.toHaveBeenCalled(); expect(onConfirm).not.toHaveBeenCalled();
  });
});
