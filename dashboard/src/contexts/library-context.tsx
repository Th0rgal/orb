'use client';

import {
  createContext,
  useContext,
  useCallback,
  useState,
  useEffect,
  useMemo,
  type ReactNode,
} from 'react';
import { useToast } from '@/components/toast';
import {
  getLibraryStatus,
  listLibrarySkills,
  syncLibrary,
  forceSyncLibrary,
  forcePushLibrary,
  commitLibrary,
  pushLibrary,
  saveLibrarySkill,
  deleteLibrarySkill,
  LibraryUnavailableError,
  DivergedHistoryError,
  type LibraryStatus,
  type SkillSummary,
} from '@/lib/api';

interface LibraryContextValue {
  // State
  status: LibraryStatus | null;
  skills: SkillSummary[];
  loading: boolean;
  libraryUnavailable: boolean;
  libraryUnavailableMessage: string | null;
  /** Set when sync fails due to diverged history (e.g., after force push on remote) */
  divergedHistory: boolean;
  divergedHistoryMessage: string | null;

  // Actions
  refresh: () => Promise<void>;
  refreshStatus: () => Promise<void>;
  sync: () => Promise<void>;
  /** Force reset local to match remote (use after diverged history) */
  forceSync: () => Promise<void>;
  /** Force push local to remote (use when you want to keep local changes) */
  forcePush: () => Promise<void>;
  commit: (message: string) => Promise<void>;
  push: () => Promise<void>;

  // Skill operations
  saveSkill: (name: string, content: string) => Promise<void>;
  removeSkill: (name: string) => Promise<void>;

  // Operation states
  syncing: boolean;
  committing: boolean;
  pushing: boolean;
}

const LibraryContext = createContext<LibraryContextValue | null>(null);

export function useLibrary() {
  const ctx = useContext(LibraryContext);
  if (!ctx) {
    throw new Error('useLibrary must be used within a LibraryProvider');
  }
  return ctx;
}

interface LibraryProviderProps {
  children: ReactNode;
}

export function LibraryProvider({ children }: LibraryProviderProps) {
  const { showError } = useToast();
  const [status, setStatus] = useState<LibraryStatus | null>(null);
  const [skills, setSkills] = useState<SkillSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [libraryUnavailable, setLibraryUnavailable] = useState(false);
  const [libraryUnavailableMessage, setLibraryUnavailableMessage] = useState<string | null>(null);

  const [syncing, setSyncing] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [pushing, setPushing] = useState(false);
  const [divergedHistory, setDivergedHistory] = useState(false);
  const [divergedHistoryMessage, setDivergedHistoryMessage] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setLibraryUnavailable(false);
    setLibraryUnavailableMessage(null);

    const results = await Promise.allSettled([
      getLibraryStatus(),
      listLibrarySkills(),
    ]);

    const errors: string[] = [];
    const handleRejection = (label: string, reason: unknown) => {
      if (reason instanceof LibraryUnavailableError) {
        setLibraryUnavailable(true);
        setLibraryUnavailableMessage(reason.message);
        setStatus(null);
        setSkills([]);
        return true;
      }
      errors.push(`${label}: ${reason instanceof Error ? reason.message : 'Failed to load'}`);
      return false;
    };

    const [statusRes, skillsRes] = results;

    if (statusRes.status === 'fulfilled') {
      setStatus(statusRes.value);
    } else if (handleRejection('Status', statusRes.reason)) {
      setLoading(false);
      return;
    }

    if (skillsRes.status === 'fulfilled') {
      setSkills(skillsRes.value);
    } else if (handleRejection('Skills', skillsRes.reason)) {
      setLoading(false);
      return;
    }

    if (errors.length > 0) {
      showError(errors[0]);
    }

    setLoading(false);
  }, [showError]);

  const refreshStatus = useCallback(async () => {
    try {
      const statusData = await getLibraryStatus();
      setStatus(statusData);
    } catch (err) {
      // Silently fail status refresh - it's not critical
      console.error('Failed to refresh status:', err);
    }
  }, []);

  // Initial load
  useEffect(() => {
    refresh();
  }, [refresh]);

  const sync = useCallback(async () => {
    try {
      setSyncing(true);
      setDivergedHistory(false);
      setDivergedHistoryMessage(null);
      await syncLibrary();
      await refresh();
    } catch (err) {
      if (err instanceof DivergedHistoryError) {
        setDivergedHistory(true);
        setDivergedHistoryMessage(err.message);
        throw err;
      }
      showError(err instanceof Error ? err.message : 'Failed to sync');
      throw err;
    } finally {
      setSyncing(false);
    }
  }, [refresh, showError]);

  const forceSync = useCallback(async () => {
    try {
      setSyncing(true);
      await forceSyncLibrary();
      setDivergedHistory(false);
      setDivergedHistoryMessage(null);
      await refresh();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Failed to force sync');
      throw err;
    } finally {
      setSyncing(false);
    }
  }, [refresh, showError]);

  const forcePush = useCallback(async () => {
    try {
      setPushing(true);
      await forcePushLibrary();
      setDivergedHistory(false);
      setDivergedHistoryMessage(null);
      await refreshStatus();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Failed to force push');
      throw err;
    } finally {
      setPushing(false);
    }
  }, [refreshStatus, showError]);

  const commit = useCallback(async (message: string) => {
    try {
      setCommitting(true);
      await commitLibrary(message);
      await refreshStatus();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Failed to commit');
      throw err;
    } finally {
      setCommitting(false);
    }
  }, [refreshStatus, showError]);

  const push = useCallback(async () => {
    try {
      setPushing(true);
      await pushLibrary();
      await refreshStatus();
    } catch (err) {
      showError(err instanceof Error ? err.message : 'Failed to push');
      throw err;
    } finally {
      setPushing(false);
    }
  }, [refreshStatus, showError]);

  const saveSkill = useCallback(async (name: string, content: string) => {
    await saveLibrarySkill(name, content);
    const skillsData = await listLibrarySkills();
    setSkills(skillsData);
    await refreshStatus();
  }, [refreshStatus]);

  const removeSkill = useCallback(async (name: string) => {
    await deleteLibrarySkill(name);
    setSkills((prev) => prev.filter((s) => s.name !== name));
    await refreshStatus();
  }, [refreshStatus]);

  const value = useMemo<LibraryContextValue>(
    () => ({
      status,
      skills,
      loading,
      libraryUnavailable,
      libraryUnavailableMessage,
      divergedHistory,
      divergedHistoryMessage,
      refresh,
      refreshStatus,
      sync,
      forceSync,
      forcePush,
      commit,
      push,
      saveSkill,
      removeSkill,
      syncing,
      committing,
      pushing,
    }),
    [
      status,
      skills,
      loading,
      libraryUnavailable,
      libraryUnavailableMessage,
      divergedHistory,
      divergedHistoryMessage,
      refresh,
      refreshStatus,
      sync,
      forceSync,
      forcePush,
      commit,
      push,
      saveSkill,
      removeSkill,
      syncing,
      committing,
      pushing,
    ]
  );

  return (
    <LibraryContext.Provider value={value}>
      {children}
    </LibraryContext.Provider>
  );
}
