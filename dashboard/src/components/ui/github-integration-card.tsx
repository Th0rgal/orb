'use client';

import { useEffect, useRef, useState } from 'react';
import useSWR from 'swr';
import { Github, Loader, Copy, Check, ExternalLink } from 'lucide-react';
import { toast } from '@/components/toast';
import { AsyncButton } from '@/components/ui/async-button';
import { useCopyToClipboard } from '@/components/tool-ui/shared/use-copy-to-clipboard';
import {
  getGithubStatus,
  authorizeGithub,
  disconnectGithub,
  type GithubIntegrationStatus,
  type GithubAuthorizeResponse,
} from '@/lib/api';

const CONNECT_POLL_FALLBACK_MS = 2000;

function formatConnectedAt(unixSeconds?: number): string | null {
  if (!unixSeconds) return null;
  const d = new Date(unixSeconds * 1000);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

interface DevicePrompt {
  userCode: string;
  verificationUri: string;
  openUrl: string;
}

/**
 * "Connect GitHub" card. Uses GitHub's device flow — the same flow as
 * `gh auth login` — so no env vars or OAuth-app setup are needed: a public
 * client_id ships in the backend.
 *
 * Connect flow: POST authorize (backend asks GitHub for a device code and
 * starts polling for the token) → show the one-time code + open
 * github.com/login/device → poll status until the token lands.
 */
export function GithubIntegrationCard() {
  const { data, isLoading, mutate } = useSWR<GithubIntegrationStatus>(
    'github-integration',
    getGithubStatus,
    { revalidateOnFocus: false },
  );

  const [device, setDevice] = useState<DevicePrompt | null>(null);
  const { copiedId, copy } = useCopyToClipboard();

  const cancelConnectRef = useRef<(() => void) | null>(null);
  useEffect(() => () => { cancelConnectRef.current?.(); }, []);

  const connect = async () => {
    cancelConnectRef.current?.();
    let cancelled = false;
    let timer: ReturnType<typeof setInterval> | undefined;
    let finishPolling: (() => void) | undefined;
    const cancel = () => {
      cancelled = true;
      clearInterval(timer);
      finishPolling?.();
    };
    cancelConnectRef.current = cancel;
    try {
      let auth: GithubAuthorizeResponse;
      try {
        auth = await authorizeGithub();
      } catch (e) {
        if (!cancelled) toast.error(e instanceof Error ? e.message : 'Failed to start GitHub authorization');
        return;
      }
      if (cancelled) return;

      const openUrl = auth.verification_uri_complete || auth.verification_uri;
      setDevice({ userCode: auth.user_code, verificationUri: auth.verification_uri, openUrl });
      window.open(openUrl, 'github-device', 'noopener,noreferrer');

      const deadline = Date.now() + auth.expires_in * 1000;
      const intervalMs = Math.max(auth.interval, 2) * 1000 || CONNECT_POLL_FALLBACK_MS;
      await new Promise<void>((resolve) => {
        finishPolling = resolve;
        let polling = false;
        timer = setInterval(async () => {
          if (cancelled || polling) return;
          polling = true;
          let status: GithubIntegrationStatus | undefined;
          try {
            status = await getGithubStatus();
          } catch {
            // Transient; keep polling while this card remains mounted.
          } finally {
            polling = false;
          }
          if (cancelled) return;
          if (status?.connected) {
            clearInterval(timer);
            toast.success(`Connected GitHub as ${status.login}`);
            setDevice(null);
            resolve();
            return;
          }
          if (Date.now() > deadline) {
            clearInterval(timer);
            toast.error('GitHub code expired before approval. Please try again.');
            setDevice(null);
            resolve();
          }
        }, intervalMs);
      });
      if (!cancelled) await mutate();
    } finally {
      clearInterval(timer);
      if (cancelConnectRef.current === cancel) cancelConnectRef.current = null;
    }
  };

  const disconnect = async () => {
    if (
      !window.confirm(
        'Disconnect GitHub? Mission agents will no longer be able to push using this account.',
      )
    ) {
      return;
    }
    try {
      await disconnectGithub();
      await mutate();
      toast.success('GitHub disconnected');
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Failed to disconnect GitHub');
    }
  };

  const copyCode = async () => {
    if (!device) return;
    const ok = await copy(device.userCode, 'github-device-code');
    if (ok) {
      toast.success('Code copied');
    } else {
      toast.error('Could not copy — select it manually');
    }
  };

  const connected = data?.connected ?? false;
  const connectedAt = formatConnectedAt(data?.connected_at);

  return (
    <section className="rounded-xl bg-white/[0.02] border border-white/[0.04] p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-white/[0.06] flex-shrink-0">
            <Github className="h-5 w-5 text-white/80" />
          </div>
          <div className="min-w-0">
            <h2 className="text-sm font-medium text-white">GitHub</h2>
            <p className="text-xs text-white/40 truncate">
              Let mission agents commit and push to your repositories
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3 flex-shrink-0">
          {isLoading ? (
            <Loader className="h-4 w-4 animate-spin text-white/40" aria-label="Loading" />
          ) : connected ? (
            <>
              <span className="flex items-center gap-1.5 text-xs text-white/50">
                <span className="h-2 w-2 rounded-full bg-emerald-400" />
                Connected
              </span>
              <AsyncButton
                onClick={disconnect}
                busyText="Disconnecting…"
                className="rounded-lg border border-white/[0.06] bg-white/[0.02] px-3 py-1.5 text-xs text-white/70 hover:bg-white/[0.04] transition-colors cursor-pointer"
              >
                Disconnect
              </AsyncButton>
            </>
          ) : (
            <AsyncButton
              onClick={connect}
              busyText="Waiting for approval…"
              className="flex items-center gap-1.5 rounded-lg bg-white/90 px-3 py-1.5 text-xs font-medium text-black hover:bg-white transition-colors cursor-pointer"
            >
              <Github className="h-3.5 w-3.5" />
              Connect GitHub
            </AsyncButton>
          )}
        </div>
      </div>

      {/* Device-flow prompt: one-time code while awaiting approval */}
      {!connected && device && (
        <div className="mt-4 rounded-lg border border-white/[0.06] bg-white/[0.01] p-4">
          <p className="text-xs text-white/50">
            Enter this code at{' '}
            <a
              href={device.verificationUri}
              target="_blank"
              rel="noopener noreferrer"
              className="text-white/70 underline underline-offset-2 hover:text-white"
            >
              github.com/login/device
            </a>{' '}
            to authorize. Waiting for approval…
          </p>
          <div className="mt-3 flex items-center gap-3">
            <code className="rounded-md bg-white/[0.06] px-3 py-1.5 font-mono text-lg tracking-[0.3em] text-white">
              {device.userCode}
            </code>
            <button
              type="button"
              onClick={copyCode}
              className="flex items-center gap-1 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2.5 py-1.5 text-xs text-white/70 hover:bg-white/[0.04] transition-colors cursor-pointer"
            >
              {copiedId === 'github-device-code' ? (
                <>
                  <Check className="h-3.5 w-3.5 text-emerald-400" /> Copied
                </>
              ) : (
                <>
                  <Copy className="h-3.5 w-3.5" /> Copy
                </>
              )}
            </button>
            <button
              type="button"
              onClick={() => window.open(device.openUrl, 'github-device', 'noopener,noreferrer')}
              className="flex items-center gap-1 rounded-lg border border-white/[0.06] bg-white/[0.02] px-2.5 py-1.5 text-xs text-white/70 hover:bg-white/[0.04] transition-colors cursor-pointer"
            >
              <ExternalLink className="h-3.5 w-3.5" /> Open
            </button>
          </div>
        </div>
      )}

      {/* Connected account detail */}
      {connected && (
        <div className="mt-4 rounded-lg border border-white/[0.06] bg-white/[0.01] p-3 text-xs">
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <span className="text-white/80">
              @{data?.login}
              {data?.name ? <span className="text-white/40"> · {data.name}</span> : null}
            </span>
            {data?.email ? <span className="text-white/40">{data.email}</span> : null}
            {connectedAt ? (
              <span className="text-white/30">Connected {connectedAt}</span>
            ) : null}
          </div>
          {data?.scopes && data.scopes.length > 0 ? (
            <div className="mt-2 flex flex-wrap gap-1.5">
              {data.scopes.map((s) => (
                <span
                  key={s}
                  className="rounded-md bg-white/[0.04] px-1.5 py-0.5 font-mono text-[10px] text-white/50"
                >
                  {s}
                </span>
              ))}
            </div>
          ) : null}
        </div>
      )}

      {/* Scope/security note for the connect path */}
      {!isLoading && !connected && !device && (
        <p className="mt-3 text-xs text-white/40 leading-relaxed">
          Sign in with GitHub (no setup needed). Authorizing grants{' '}
          <code className="font-mono text-white/55">repo</code> access (push to private and public
          repositories) to this server. The token is stored on the server and made available to
          mission agents inside their workspaces.
        </p>
      )}
    </section>
  );
}
