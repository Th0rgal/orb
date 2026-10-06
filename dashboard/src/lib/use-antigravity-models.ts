import useSWR from 'swr';
import { listAntigravityModels } from './api';

/** Account models belong to the execution workspace, not the API-provider catalog. */
export function useAntigravityModels(backend: string, workspace: string, enabled: boolean, model: string) {
  const native = backend === 'antigravity';
  const { data, error, isLoading, mutate } = useSWR(
    enabled && native ? ['antigravity-models', workspace] : null,
    () => listAntigravityModels(workspace || undefined),
    { keepPreviousData: false, revalidateOnFocus: true, suspense: false },
  );
  return {
    native,
    options: (data ?? []).map(([value, label]) => ({ value, label })),
    ready: backend !== 'gemini' && (!native || (!error && !isLoading && !!model && !!data?.some(([id]) => id === model))),
    message: isLoading ? 'Discovering workspace models…' : error
      ? 'Discovery failed. Sign in with agy in this workspace, then refresh.'
      : !data?.length ? 'No native models found. Sign in with agy in this workspace, then refresh.'
      : 'Select a model from this workspace’s Antigravity account.',
    refresh: () => mutate().catch(() => undefined),
  };
}
