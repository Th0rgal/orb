import { StrictMode } from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { authorizeGithub, getGithubStatus, type GithubAuthorizeResponse, type GithubIntegrationStatus } from '@/lib/api';
import { GithubIntegrationCard } from './github-integration-card';
const { success, error, mutate } = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn(), mutate: vi.fn().mockResolvedValue(undefined) }));
vi.mock('@/components/toast', () => ({ toast: { success, error } }));
vi.mock('swr', () => ({ default: () => ({ data: { connected: false, scopes: [] }, isLoading: false, mutate }) }));
vi.mock('@/lib/api', () => ({ authorizeGithub: vi.fn(), getGithubStatus: vi.fn(), disconnectGithub: vi.fn() }));
const auth: GithubAuthorizeResponse = { user_code: 'FIXTURE', verification_uri: 'https://github.com/login/device', expires_in: 60, interval: 2 };
const offline: GithubIntegrationStatus = { configured: true, connected: false, scopes: [] };
const connected: GithubIntegrationStatus = { ...offline, connected: true, login: 'fixture-user' };
function deferred<T>() {
  let resolve!: (value: T) => void; let reject!: (reason: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
async function start() {
  const view = render(<StrictMode><GithubIntegrationCard /></StrictMode>);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Connect GitHub/ })));
  return view;
}
async function tick(ms = 2000) { await act(async () => vi.advanceTimersByTimeAsync(ms)); }
beforeEach(() => {
  vi.useFakeTimers(); vi.clearAllMocks();
  vi.mocked(authorizeGithub).mockResolvedValue(auth);
  vi.mocked(getGithubStatus).mockResolvedValue(offline);
  vi.spyOn(window, 'open').mockReturnValue(null);
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });
describe('GitHub device polling lifetime', () => {
  it('stops future polls when the card unmounts', async () => {
    const view = await start(); await tick();
    expect(getGithubStatus).toHaveBeenCalledTimes(1);
    view.unmount(); await tick(10000);
    expect(getGithubStatus).toHaveBeenCalledTimes(1);
    expect(success).not.toHaveBeenCalled(); expect(error).not.toHaveBeenCalled(); expect(mutate).not.toHaveBeenCalled();
  });
  it.each(['success', 'failure'])('ignores in-flight status %s after unmount', async (result) => {
    const pending = deferred<GithubIntegrationStatus>();
    vi.mocked(getGithubStatus).mockReturnValueOnce(pending.promise);
    const view = await start(); await tick(); view.unmount();
    await act(async () => { if (result === 'success') pending.resolve(connected); else pending.reject(new Error('Offline')); });
    await tick(100000);
    expect(getGithubStatus).toHaveBeenCalledTimes(1);
    expect(success).not.toHaveBeenCalled(); expect(error).not.toHaveBeenCalled(); expect(mutate).not.toHaveBeenCalled();
  });
  it.each(['success', 'failure'])('ignores authorization %s after unmount', async (result) => {
    const pending = deferred<GithubAuthorizeResponse>();
    vi.mocked(authorizeGithub).mockReturnValueOnce(pending.promise);
    const view = await start(); view.unmount();
    await act(async () => { if (result === 'success') pending.resolve(auth); else pending.reject(new Error('Offline')); });
    await tick(100000);
    expect(window.open).not.toHaveBeenCalled(); expect(getGithubStatus).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled(); expect(mutate).not.toHaveBeenCalled();
  });
  it('keeps a remounted attempt independent of a late response from the old card', async () => {
    const old = deferred<GithubIntegrationStatus>();
    vi.mocked(getGithubStatus).mockReturnValueOnce(old.promise).mockResolvedValue(connected);
    const first = await start(); await tick(); first.unmount();
    await start(); await tick();
    expect(success).toHaveBeenCalledTimes(1); expect(mutate).toHaveBeenCalledTimes(1);
    await act(async () => old.resolve(connected)); await tick(10000);
    expect(success).toHaveBeenCalledTimes(1); expect(mutate).toHaveBeenCalledTimes(1);
    expect(getGithubStatus).toHaveBeenCalledTimes(2);
  });
  it('reports authorization failure while mounted and releases the connect button', async () => {
    vi.mocked(authorizeGithub).mockRejectedValueOnce(new Error('Authorization unavailable'));
    await start();
    expect(error).toHaveBeenCalledWith('Authorization unavailable');
    expect(screen.getByRole('button', { name: /Connect GitHub/ })).toBeEnabled();
    expect(window.open).not.toHaveBeenCalled(); expect(getGithubStatus).not.toHaveBeenCalled();
  });
  it('does not overlap slow status polls and stops after approval', async () => {
    const pending = deferred<GithubIntegrationStatus>();
    vi.mocked(getGithubStatus).mockReturnValueOnce(pending.promise);
    await start(); await tick(8000);
    expect(getGithubStatus).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(connected));
    expect(success).toHaveBeenCalledTimes(1); expect(success).toHaveBeenCalledWith('Connected GitHub as fixture-user');
    expect(mutate).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('FIXTURE')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Connect GitHub/ })).toBeEnabled();
    await tick(10000); expect(getGithubStatus).toHaveBeenCalledTimes(1);
  });
  it('retries transient errors while mounted and expires with feedback', async () => {
    vi.mocked(authorizeGithub).mockResolvedValue({ ...auth, expires_in: 3 });
    vi.mocked(getGithubStatus).mockRejectedValueOnce(new Error('Offline')).mockResolvedValue(offline);
    await start(); await tick(); expect(error).not.toHaveBeenCalled(); await tick();
    expect(getGithubStatus).toHaveBeenCalledTimes(2);
    expect(error).toHaveBeenCalledWith('GitHub code expired before approval. Please try again.');
    expect(mutate).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('button', { name: /Connect GitHub/ })).toBeEnabled();
    await tick(10000); expect(getGithubStatus).toHaveBeenCalledTimes(2);
  });
});
