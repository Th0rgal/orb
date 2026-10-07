import type { ReactNode } from "react";

export function ArchitectureDiagram() {
  return (
    <div className="orb-arch" role="region" aria-label="Orb and sandboxed.sh architecture">
      {/* Tier 1: Unified Clients & Coordinator */}
      <div className="orb-arch-tier">
        <div className="orb-arch-tier-header">
          <span className="orb-arch-badge orb-arch-badge-blue">Clients &amp; Coordinator</span>
          <span className="orb-arch-tier-sub">Every surface shares the same project roster and live event stream</span>
        </div>
        <div className="orb-arch-grid orb-arch-grid-4">
          <div className="orb-arch-node">
            <div className="orb-arch-node-title">
              <span className="orb-arch-dot orb-arch-dot-blue" />
              Orb Desktop
            </div>
            <div className="orb-arch-node-meta">macOS · Tauri + SolidJS</div>
          </div>
          <div className="orb-arch-node">
            <div className="orb-arch-node-title">
              <span className="orb-arch-dot orb-arch-dot-blue" />
              Orb iOS
            </div>
            <div className="orb-arch-node-meta">iPhone &amp; iPad · SwiftUI</div>
          </div>
          <div className="orb-arch-node">
            <div className="orb-arch-node-title">
              <span className="orb-arch-dot orb-arch-dot-muted" />
              Web Admin Console
            </div>
            <div className="orb-arch-node-meta">Next.js · Fleet &amp; Containers</div>
          </div>
          <div className="orb-arch-node">
            <div className="orb-arch-node-title">
              <span className="orb-arch-dot orb-arch-dot-purple" />
              Hermes Coordinator
            </div>
            <div className="orb-arch-node-meta">Autonomous Crons · MCP</div>
          </div>
        </div>
      </div>

      {/* Connectors */}
      <div className="orb-arch-connectors">
        <div className="orb-arch-connector">
          <span className="orb-arch-line" />
          <span className="orb-arch-pill">
            <code>placement: &quot;client&quot;</code> · Local CLI spawn
          </span>
          <span className="orb-arch-arrow">↓</span>
        </div>
        <div className="orb-arch-connector">
          <span className="orb-arch-line" />
          <span className="orb-arch-pill">
            HTTPS · SSE <code>/snapshot</code> + <code>/events</code> · Unified MCP
          </span>
          <span className="orb-arch-arrow">↓</span>
        </div>
      </div>

      {/* Tier 2: Your Computer vs Core Server */}
      <div className="orb-arch-split">
        <div className="orb-arch-card">
          <div className="orb-arch-card-head">
            <div>
              <span className="orb-arch-badge orb-arch-badge-green">Mode 1 · Local</span>
              <h4 className="orb-arch-card-title">Your Computer</h4>
            </div>
            <code>~/.orb/</code>
          </div>
          <ul className="orb-arch-list">
            <li>
              <strong>Native Harnesses:</strong> Spawns local{" "}
              <code>claude</code>, <code>codex</code>, <code>agy</code>,{" "}
              <code>opencode</code>, or <code>grok</code> directly in your repo
            </li>
            <li>
              <strong>Durable Outbox:</strong> Queues turns offline and mirrors transcripts to Core so iOS stays in sync
            </li>
            <li>
              <strong>Shared Context:</strong> Syncs <code>@context</code> files and native{" "}
              <code>SKILL.md</code> bundles across machines
            </li>
          </ul>
        </div>

        <div className="orb-arch-card orb-arch-card-core">
          <div className="orb-arch-card-head">
            <div>
              <span className="orb-arch-badge orb-arch-badge-blue">Modes 2 &amp; 3 · Control Plane</span>
              <h4 className="orb-arch-card-title">Core Server (<code>sandboxed-sh</code>)</h4>
            </div>
            <code>:3000</code>
          </div>
          <ul className="orb-arch-list">
            <li>
              <strong>State &amp; Streams:</strong> SQLite <code>projects.db</code>, mission history, cursor pagination, and durable wake-ups
            </li>
            <li>
              <strong>Unified MCP (<code>/api/mcp</code>):</strong> Scoped{" "}
              <code>mcp1.</code> tokens + idempotent action receipts via{" "}
              <code>sandboxed-mcp</code>
            </li>
            <li>
              <strong>CLIProxyAPI &amp; Cloud:</strong> OAuth token refresh for Claude/Codex/Antigravity + Hermes, ChatGPT, Grok Bot, Cursor Cloud
            </li>
          </ul>

          {/* Sub-connectors from Core Server */}
          <div className="orb-arch-subconnectors">
            <div className="orb-arch-subbranch">
              <span className="orb-arch-sublabel">Local Cgroups</span>
              <div className="orb-arch-subcard">
                <div className="orb-arch-subcard-title">Core Workspaces</div>
                <p>
                  Host or <code>systemd-nspawn</code> containers inside{" "}
                  <code>missions.slice</code> (<code>MemoryMax</code> /{" "}
                  <code>CPUQuota</code>)
                </p>
              </div>
            </div>
            <div className="orb-arch-subbranch">
              <span className="orb-arch-sublabel">Lease JWT</span>
              <div className="orb-arch-subcard">
                <div className="orb-arch-subcard-title">Remote Nodes &amp; Spark</div>
                <p>
                  <code>sandboxed-node</code> fleet workers (<code>:3088</code>) + DGX Spark P0 Lean offload
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export function IosShowcase() {
  return (
    <div className="orb-ios-showcase">
      <figure className="orb-ios-card">
        <div className="orb-ios-frame">
          <img
            src="/images/orb-ios-projects.webp"
            alt="Orb iOS Projects list"
            loading="lazy"
          />
        </div>
        <figcaption>
          <strong>Projects &amp; Unread Activity</strong>
          <span>Jump between active repositories, controllers, and unread turns on iPhone.</span>
        </figcaption>
      </figure>

      <figure className="orb-ios-card">
        <div className="orb-ios-frame">
          <img
            src="/images/orb-ios.webp"
            alt="Orb iOS live mission transcript"
            loading="lazy"
          />
        </div>
        <figcaption>
          <strong>Live Mission Transcript</strong>
          <span>Inspect tool folds, file links, and send follow-up instructions from anywhere.</span>
        </figcaption>
      </figure>
    </div>
  );
}

export function DesktopShowcase({
  src,
  alt,
  caption,
}: {
  src: string;
  alt: string;
  caption?: ReactNode;
}) {
  return (
    <figure className="orb-desktop-figure">
      <div className="orb-desktop-frame">
        <img src={src} alt={alt} loading="lazy" />
      </div>
      {caption && <figcaption className="orb-desktop-caption">{caption}</figcaption>}
    </figure>
  );
}
