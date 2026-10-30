'use client';

import { useEffect, useMemo, useState } from 'react';
import { toast } from '@/components/toast';
import {
  type McpScope,
  type McpServerState,
  type McpTransport,
  type McpStatus,
  type UpdateMcpRequest,
  listMcps,
  enableMcp,
  disableMcp,
  refreshMcp,
  updateMcp,
} from '@/lib/api';
import {
  Check,
  Loader,
  Plus,
  RefreshCw,
  Search,
  X,
  Power,
  Zap,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { CopyButton } from '@/components/ui/copy-button';

function RuntimeMcpCard({
  mcp,
  isSelected,
  onSelect,
  onToggle,
  onRefresh,
}: {
  mcp: McpServerState;
  isSelected: boolean;
  onSelect: (mcp: McpServerState | null) => void;
  onToggle: (id: string, enabled: boolean) => Promise<void>;
  onRefresh: (id: string) => Promise<void>;
}) {
  const [toggling, setToggling] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const statusColor: Record<McpStatus, string> = {
    connected: 'text-emerald-400',
    connecting: 'text-amber-400',
    disconnected: 'text-white/40',
    disabled: 'text-white/40',
    error: 'text-red-400',
  };

  const statusLabel: Record<McpStatus, string> = {
    connected: 'Connected',
    connecting: 'Connecting...',
    disconnected: 'Disconnected',
    disabled: 'Disabled',
    error: 'Error',
  };

  const handleToggle = async (e: React.MouseEvent) => {
    e.stopPropagation();
    setToggling(true);
    try {
      await onToggle(mcp.id, !mcp.enabled);
    } finally {
      setToggling(false);
    }
  };

  const handleRefresh = async (e: React.MouseEvent) => {
    e.stopPropagation();
    setRefreshing(true);
    try {
      await onRefresh(mcp.id);
    } finally {
      setRefreshing(false);
    }
  };

  const handleSelect = () => onSelect(isSelected ? null : mcp);

  return (
    <div
      role="button"
      tabIndex={0}
      aria-pressed={isSelected}
      onClick={handleSelect}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          handleSelect();
        }
      }}
      className={cn(
        'w-full rounded-xl p-4 text-left transition-all cursor-pointer',
        'bg-white/[0.02] border hover:bg-white/[0.04] focus:outline-none focus:ring-1 focus:ring-cyan-500/40',
        isSelected
          ? 'border-cyan-500/40 bg-cyan-500/5'
          : 'border-white/[0.04] hover:border-white/[0.08]'
      )}
    >
      <div className="flex items-start gap-3 mb-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-cyan-500/10">
          <Zap className="h-5 w-5 text-cyan-400" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <h3 className="font-medium text-white truncate">{mcp.name}</h3>
            <span className="tag bg-cyan-500/10 text-cyan-400 border-cyan-500/20">Runtime</span>
            {(mcp.name === 'workspace' || mcp.name === 'desktop') && (
              <span className="tag bg-violet-500/10 text-violet-400 border-violet-500/20">Builtin</span>
            )}
            <span
              className={cn(
                'tag',
                mcp.scope === 'workspace'
                  ? 'bg-amber-500/10 text-amber-400 border-amber-500/20'
                  : 'bg-white/[0.04] text-white/50 border-white/[0.08]'
              )}
            >
              {mcp.scope === 'workspace' ? 'Workspace' : 'Global'}
            </span>
          </div>
          <div className="flex items-center gap-1 group">
            <p className="text-xs text-white/40 truncate">
              {mcp.endpoint || 'stdio'}
            </p>
            {mcp.endpoint && <CopyButton text={mcp.endpoint} showOnHover label="Copied endpoint" />}
          </div>
        </div>
      </div>

      <div className="flex flex-wrap gap-1 mb-3">
        {mcp.tools.slice(0, 3).map((tool) => (
          <span key={tool} className="tag">
            {tool}
          </span>
        ))}
        {mcp.tools.length > 3 && <span className="tag">+{mcp.tools.length - 3}</span>}
        {mcp.tools.length === 0 && (
          <span className="text-[10px] text-white/30">No tools discovered</span>
        )}
      </div>

      <div className="flex items-center justify-between pt-3 border-t border-white/[0.04]">
        <div className="flex items-center gap-2">
          <span className={cn(
            'h-2 w-2 rounded-full',
            mcp.status === 'connected' && 'bg-emerald-400',
            mcp.status === 'connecting' && 'bg-amber-400 animate-pulse',
            mcp.status === 'disconnected' && 'bg-white/40',
            mcp.status === 'disabled' && 'bg-white/40',
            mcp.status === 'error' && 'bg-red-400'
          )} />
          <span className={cn('text-[10px]', statusColor[mcp.status])}>{statusLabel[mcp.status]}</span>
          {mcp.error && (
            <span className="text-[10px] text-red-400 truncate max-w-[120px]" title={mcp.error}>
              {mcp.error}
            </span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={handleRefresh}
            disabled={refreshing}
            className="flex h-6 w-6 items-center justify-center rounded text-white/40 hover:bg-white/[0.06] hover:text-white transition-colors disabled:opacity-50"
            title="Refresh MCP"
          >
            <RefreshCw className={cn('h-3 w-3', refreshing && 'animate-spin')} />
          </button>
          <button
            onClick={handleToggle}
            disabled={toggling}
            className={cn(
              'flex h-6 w-6 items-center justify-center rounded transition-colors disabled:opacity-50',
              mcp.enabled
                ? 'text-emerald-400 hover:bg-emerald-500/10'
                : 'text-white/40 hover:bg-white/[0.06]'
            )}
            title={mcp.enabled ? 'Disable MCP' : 'Enable MCP'}
          >
            <Power className="h-3 w-3" />
          </button>
        </div>
      </div>
    </div>
  );
}

function RuntimeMcpDetailPanel({
  mcp,
  onClose,
  onUpdate,
  onRefresh,
}: {
  mcp: McpServerState;
  onClose: () => void;
  onUpdate: (id: string, updates: UpdateMcpRequest) => Promise<void>;
  onRefresh: (id: string) => Promise<void>;
}) {
  const isStdio = 'stdio' in (mcp.transport ?? {});
  const isHttp = 'http' in (mcp.transport ?? {});
  const stdioConfig = isStdio ? (mcp.transport as { stdio: { command: string; args: string[]; env: Record<string, string> } }).stdio : null;
  const httpConfig = isHttp ? (mcp.transport as { http: { endpoint: string; headers: Record<string, string> } }).http : null;
  const [scope, setScope] = useState<McpScope>(mcp.scope ?? 'global');

  const [keyValuePairs, setKeyValuePairs] = useState<Array<{ key: string; value: string }>>(
    () => {
      if (isStdio) {
        return Object.entries(stdioConfig?.env ?? {}).map(([key, value]) => ({ key, value }));
      }
      if (isHttp) {
        return Object.entries(httpConfig?.headers ?? {}).map(([key, value]) => ({ key, value }));
      }
      return [];
    }
  );
  const [newKey, setNewKey] = useState('');
  const [newValue, setNewValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if ('stdio' in (mcp.transport ?? {})) {
      const config = (mcp.transport as { stdio: { command: string; args: string[]; env: Record<string, string> } }).stdio;
      setKeyValuePairs(Object.entries(config?.env ?? {}).map(([key, value]) => ({ key, value })));
    } else if ('http' in (mcp.transport ?? {})) {
      const config = (mcp.transport as { http: { endpoint: string; headers: Record<string, string> } }).http;
      setKeyValuePairs(Object.entries(config?.headers ?? {}).map(([key, value]) => ({ key, value })));
    }
    setScope(mcp.scope ?? 'global');
  }, [mcp.transport, mcp.scope]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  const handleAddKeyValue = () => {
    if (!newKey.trim()) return;
    setKeyValuePairs((prev) => [...prev, { key: newKey.trim(), value: newValue }]);
    setNewKey('');
    setNewValue('');
  };

  const handleRemoveKeyValue = (index: number) => {
    setKeyValuePairs((prev) => prev.filter((_, i) => i !== index));
  };

  const handleUpdateKeyValue = (index: number, field: 'key' | 'value', value: string) => {
    setKeyValuePairs((prev) =>
      prev.map((item, i) => (i === index ? { ...item, [field]: value } : item))
    );
  };

  const handleSave = async () => {
    if (!stdioConfig && !httpConfig) return;
    setSaving(true);
    try {
      const newMap: Record<string, string> = {};
      keyValuePairs.forEach(({ key, value }) => {
        if (key.trim()) {
          newMap[key.trim()] = value;
        }
      });

      let transport: McpTransport;
      if (stdioConfig) {
        transport = {
          stdio: {
            command: stdioConfig.command,
            args: stdioConfig.args,
            env: newMap,
          },
        };
      } else if (httpConfig) {
        transport = {
          http: {
            endpoint: httpConfig.endpoint,
            headers: newMap,
          },
        };
      } else {
        return;
      }

      await onUpdate(mcp.id, { transport, scope });
      toast.success(isStdio ? 'Saved environment variables' : 'Saved headers');
    } catch {
      toast.error('Failed to save');
    } finally {
      setSaving(false);
    }
  };

  const handleRefresh = async () => {
    setRefreshing(true);
    try {
      await onRefresh(mcp.id);
      toast.success('Refreshed MCP');
    } catch {
      toast.error('Failed to refresh');
    } finally {
      setRefreshing(false);
    }
  };

  const statusColorMap: Record<McpStatus, string> = {
    connected: 'text-emerald-400',
    connecting: 'text-amber-400',
    disconnected: 'text-white/40',
    disabled: 'text-white/40',
    error: 'text-red-400',
  };

  return (
    <>
      <div
        className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm animate-fade-in"
        onClick={onClose}
      />
      <div
        className="fixed right-0 top-0 z-50 h-full w-96 flex flex-col glass-panel border-l border-white/[0.06] animate-slide-in-right"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between border-b border-white/[0.06] p-4">
          <div>
            <div className="flex items-center gap-2">
              <h2 className="text-lg font-semibold text-white">{mcp.name}</h2>
              <span className="tag bg-cyan-500/10 text-cyan-400 border-cyan-500/20">Runtime</span>
              {(mcp.name === 'workspace' || mcp.name === 'desktop') && (
                <span className="tag bg-violet-500/10 text-violet-400 border-violet-500/20">Builtin</span>
              )}
              <span
                className={cn(
                  'tag',
                  scope === 'workspace'
                    ? 'bg-amber-500/10 text-amber-400 border-amber-500/20'
                    : 'bg-white/[0.04] text-white/50 border-white/[0.08]'
                )}
              >
                {scope === 'workspace' ? 'Workspace' : 'Global'}
              </span>
            </div>
            <div className="flex items-center gap-2 mt-1">
              <span className={cn(
                'h-2 w-2 rounded-full',
                mcp.status === 'connected' && 'bg-emerald-400',
                mcp.status === 'connecting' && 'bg-amber-400 animate-pulse',
                mcp.status === 'disconnected' && 'bg-white/40',
                mcp.status === 'disabled' && 'bg-white/40',
                mcp.status === 'error' && 'bg-red-400'
              )} />
              <span className={cn('text-xs', statusColorMap[mcp.status])}>
                {mcp.status.charAt(0).toUpperCase() + mcp.status.slice(1)}
              </span>
              {mcp.version && <span className="text-xs text-white/30">v{mcp.version}</span>}
            </div>
          </div>
          <button
            onClick={onClose}
            className="flex h-8 w-8 items-center justify-center rounded-lg text-white/50 hover:bg-white/[0.04] hover:text-white transition-colors"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
            <p className="text-xs text-white/40 mb-2">Scope</p>
            <div className="flex items-center gap-2">
              <select
                value={scope}
                onChange={(e) => setScope(e.target.value as McpScope)}
                className="w-full rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-2 text-xs text-white focus:border-cyan-500/50 focus:outline-none"
              >
                <option value="global">Global (host-level)</option>
                <option value="workspace">Workspace (installed per workspace)</option>
              </select>
            </div>
            <p className="mt-2 text-[11px] text-white/40">
              Workspace-scoped MCPs must be installed in the workspace init script.
            </p>
          </div>

          {isStdio && stdioConfig && (
            <>
              <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
                <p className="text-xs text-white/40 mb-2">Command</p>
                <div className="flex flex-wrap gap-1">
                  <span className="tag">{stdioConfig.command}</span>
                  {stdioConfig.args.map((arg, idx) => (
                    <span key={idx} className="tag">
                      {arg}
                    </span>
                  ))}
                </div>
              </div>

              <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
                <div className="flex items-center justify-between mb-3">
                  <p className="text-xs text-white/40">Environment Variables</p>
                </div>

                {keyValuePairs.length === 0 ? (
                  <p className="text-sm text-white/40 mb-3">No environment variables configured</p>
                ) : (
                  <div className="space-y-2 mb-3">
                    {keyValuePairs.map((item, idx) => (
                      <div key={idx} className="flex items-center gap-2">
                        <input
                          type="text"
                          value={item.key}
                          onChange={(e) => handleUpdateKeyValue(idx, 'key', e.target.value)}
                          placeholder="KEY"
                          className="flex-1 min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                        />
                        <input
                          type="text"
                          value={item.value}
                          onChange={(e) => handleUpdateKeyValue(idx, 'value', e.target.value)}
                          placeholder="value"
                          className="flex-[2] min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                        />
                        <button
                          onClick={() => handleRemoveKeyValue(idx)}
                          className="flex h-7 w-7 items-center justify-center rounded-lg text-white/40 hover:bg-red-500/10 hover:text-red-400 transition-colors"
                        >
                          <X className="h-3 w-3" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}

                <div className="flex items-center gap-2 pt-2 border-t border-white/[0.04]">
                  <input
                    type="text"
                    value={newKey}
                    onChange={(e) => setNewKey(e.target.value)}
                    placeholder="NEW_KEY"
                    className="flex-1 min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                    onKeyDown={(e) => e.key === 'Enter' && handleAddKeyValue()}
                  />
                  <input
                    type="text"
                    value={newValue}
                    onChange={(e) => setNewValue(e.target.value)}
                    placeholder="value"
                    className="flex-[2] min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                    onKeyDown={(e) => e.key === 'Enter' && handleAddKeyValue()}
                  />
                  <button
                    onClick={handleAddKeyValue}
                    disabled={!newKey.trim()}
                    className="flex h-7 w-7 items-center justify-center rounded-lg bg-cyan-500/10 text-cyan-400 hover:bg-cyan-500/20 transition-colors disabled:opacity-50"
                  >
                    <Plus className="h-3 w-3" />
                  </button>
                </div>
              </div>
            </>
          )}

          {isHttp && httpConfig && (
            <>
              <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
                <p className="text-xs text-white/40 mb-2">Endpoint</p>
                <div className="flex items-center gap-2 group">
                  <p className="text-sm text-white break-all">
                    {httpConfig.endpoint || 'HTTP transport'}
                  </p>
                  {httpConfig.endpoint && <CopyButton text={httpConfig.endpoint} showOnHover label="Copied endpoint" />}
                </div>
              </div>

              <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
                <div className="flex items-center justify-between mb-3">
                  <p className="text-xs text-white/40">Headers</p>
                </div>

                {keyValuePairs.length === 0 ? (
                  <p className="text-sm text-white/40 mb-3">No headers configured</p>
                ) : (
                  <div className="space-y-2 mb-3">
                    {keyValuePairs.map((item, idx) => (
                      <div key={idx} className="flex items-center gap-2">
                        <input
                          type="text"
                          value={item.key}
                          onChange={(e) => handleUpdateKeyValue(idx, 'key', e.target.value)}
                          placeholder="Header-Name"
                          className="flex-1 min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                        />
                        <input
                          type="text"
                          value={item.value}
                          onChange={(e) => handleUpdateKeyValue(idx, 'value', e.target.value)}
                          placeholder="value"
                          className="flex-[2] min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                        />
                        <button
                          onClick={() => handleRemoveKeyValue(idx)}
                          className="flex h-7 w-7 items-center justify-center rounded-lg text-white/40 hover:bg-red-500/10 hover:text-red-400 transition-colors"
                        >
                          <X className="h-3 w-3" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}

                <div className="flex items-center gap-2 pt-2 border-t border-white/[0.04]">
                  <input
                    type="text"
                    value={newKey}
                    onChange={(e) => setNewKey(e.target.value)}
                    placeholder="Authorization"
                    className="flex-1 min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                    onKeyDown={(e) => e.key === 'Enter' && handleAddKeyValue()}
                  />
                  <input
                    type="text"
                    value={newValue}
                    onChange={(e) => setNewValue(e.target.value)}
                    placeholder="Bearer ..."
                    className="flex-[2] min-w-0 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2 py-1.5 text-xs text-white placeholder-white/30 focus:border-cyan-500/50 focus:outline-none"
                    onKeyDown={(e) => e.key === 'Enter' && handleAddKeyValue()}
                  />
                  <button
                    onClick={handleAddKeyValue}
                    disabled={!newKey.trim()}
                    className="flex h-7 w-7 items-center justify-center rounded-lg bg-cyan-500/10 text-cyan-400 hover:bg-cyan-500/20 transition-colors disabled:opacity-50"
                  >
                    <Plus className="h-3 w-3" />
                  </button>
                </div>
              </div>
            </>
          )}

          <div className="rounded-xl bg-white/[0.02] border border-white/[0.06] p-4">
            <p className="text-xs text-white/40 mb-2">Tools ({mcp.tools.length})</p>
            {mcp.tools.length === 0 ? (
              <p className="text-sm text-white/40">No tools discovered</p>
            ) : (
              <div className="flex flex-wrap gap-1 max-h-32 overflow-y-auto">
                {mcp.tools.map((tool) => (
                  <span key={tool} className="tag">
                    {tool}
                  </span>
                ))}
              </div>
            )}
          </div>

          {mcp.error && (
            <div className="rounded-xl bg-red-500/10 border border-red-500/20 p-4">
              <p className="text-xs text-red-400 mb-1">Error</p>
              <p className="text-sm text-red-300">{mcp.error}</p>
            </div>
          )}
        </div>

        <div className="border-t border-white/[0.06] p-4 flex items-center gap-2">
          {(isStdio || isHttp) && (
            <button
              onClick={handleSave}
              disabled={saving}
              className="flex-1 flex items-center justify-center gap-2 rounded-lg bg-cyan-500/10 hover:bg-cyan-500/20 border border-cyan-500/20 px-3 py-2 text-sm text-cyan-300 transition-colors disabled:opacity-50"
            >
              {saving ? <Loader className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
              Save
            </button>
          )}
          <button
            onClick={handleRefresh}
            disabled={refreshing}
            className="flex items-center justify-center gap-2 rounded-lg bg-white/[0.04] hover:bg-white/[0.08] border border-white/[0.06] px-3 py-2 text-sm text-white/80 transition-colors disabled:opacity-50"
          >
            <RefreshCw className={cn('h-4 w-4', refreshing && 'animate-spin')} />
            Refresh
          </button>
        </div>
      </div>
    </>
  );
}

export default function McpsPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [runtimeMcps, setRuntimeMcps] = useState<McpServerState[]>([]);
  const [runtimeLoading, setRuntimeLoading] = useState(true);
  const [selectedRuntimeMcp, setSelectedRuntimeMcp] = useState<McpServerState | null>(null);

  useEffect(() => {
    const fetchRuntimeMcps = async () => {
      try {
        const mcps = await listMcps();
        setRuntimeMcps(mcps);
      } catch (err) {
        console.error('Failed to fetch runtime MCPs:', err);
      } finally {
        setRuntimeLoading(false);
      }
    };
    fetchRuntimeMcps();

    const interval = setInterval(async () => {
      try {
        const mcps = await listMcps();
        setRuntimeMcps(mcps);
        setSelectedRuntimeMcp((prev) => {
          if (!prev) return null;
          const updated = mcps.find((m) => m.id === prev.id);
          return updated ?? null;
        });
      } catch (err) {
        console.error('Failed to poll runtime MCPs:', err);
      }
    }, 5000);

    return () => clearInterval(interval);
  }, []);

  const handleToggleRuntimeMcp = async (id: string, enabled: boolean) => {
    try {
      const updated = enabled ? await enableMcp(id) : await disableMcp(id);
      setRuntimeMcps((prev) => prev.map((m) => (m.id === id ? updated : m)));
      toast.success(`${enabled ? 'Enabled' : 'Disabled'} MCP`);
    } catch {
      toast.error('Failed to toggle MCP');
    }
  };

  const handleRefreshRuntimeMcp = async (id: string) => {
    try {
      const updated = await refreshMcp(id);
      setRuntimeMcps((prev) => prev.map((m) => (m.id === id ? updated : m)));
      setSelectedRuntimeMcp((prev) => (prev?.id === id ? updated : prev));
      toast.success('Refreshed MCP');
    } catch {
      toast.error('Failed to refresh MCP');
    }
  };

  const handleUpdateRuntimeMcp = async (id: string, updates: UpdateMcpRequest) => {
    const updated = await updateMcp(id, updates);
    setRuntimeMcps((prev) => prev.map((m) => (m.id === id ? updated : m)));
    setSelectedRuntimeMcp((prev) => (prev?.id === id ? updated : prev));
  };

  const filteredRuntimeMcps = useMemo(() => {
    if (!searchQuery.trim()) return runtimeMcps;
    const query = searchQuery.toLowerCase();
    return runtimeMcps.filter((mcp) => {
      return (
        mcp.name.toLowerCase().includes(query) ||
        mcp.endpoint?.toLowerCase().includes(query) ||
        mcp.tools.some((t) => t.toLowerCase().includes(query))
      );
    });
  }, [runtimeMcps, searchQuery]);

  return (
    <div className="p-6 max-w-6xl mx-auto space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-white">MCP Servers</h1>
        <p className="text-sm text-white/40">Runtime MCP servers registered with Core.</p>
      </div>

      <div className="relative">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-white/30" />
        <input
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search MCPs..."
          className="w-full rounded-xl border border-white/[0.06] bg-white/[0.02] pl-10 pr-4 py-2.5 text-sm text-white placeholder-white/30 focus:border-indigo-500/50 focus:outline-none transition-colors"
        />
      </div>

      {filteredRuntimeMcps.length > 0 && (
        <div className="space-y-3">
          <div className="flex items-center gap-2">
            <Zap className="h-4 w-4 text-cyan-400" />
            <h2 className="text-sm font-medium text-white/70">Runtime MCPs</h2>
            <span className="text-xs text-white/40">Auto-registered servers</span>
          </div>
          <div className="grid gap-4 md:grid-cols-2">
            {filteredRuntimeMcps.map((mcp) => (
              <RuntimeMcpCard
                key={mcp.id}
                mcp={mcp}
                isSelected={selectedRuntimeMcp?.id === mcp.id}
                onSelect={setSelectedRuntimeMcp}
                onToggle={handleToggleRuntimeMcp}
                onRefresh={handleRefreshRuntimeMcp}
              />
            ))}
          </div>
        </div>
      )}

      {runtimeLoading && filteredRuntimeMcps.length === 0 && (
        <div className="flex items-center justify-center p-4">
          <Loader className="h-5 w-5 animate-spin text-white/40" />
        </div>
      )}

      {filteredRuntimeMcps.length === 0 && !runtimeLoading && (
        <div className="rounded-xl border border-white/[0.06] bg-white/[0.02] p-8 text-center">
          <p className="text-sm text-white/40">
            {searchQuery.trim()
              ? 'No MCPs match your search.'
              : 'No MCP servers configured yet.'}
          </p>
        </div>
      )}

      {selectedRuntimeMcp && (
        <RuntimeMcpDetailPanel
          mcp={selectedRuntimeMcp}
          onClose={() => setSelectedRuntimeMcp(null)}
          onUpdate={handleUpdateRuntimeMcp}
          onRefresh={handleRefreshRuntimeMcp}
        />
      )}
    </div>
  );
}
