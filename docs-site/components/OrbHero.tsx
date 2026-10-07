"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";

declare global {
  interface Window {
    ORB_SPEC_F32_B64?: string;
    initOrbShaderCanvas?: (
      canvas: HTMLCanvasElement,
      opts?: {
        width?: number;
        height?: number;
        radius?: number;
        speed?: number;
        flowAmp?: number;
        metalAmp?: number;
        relightAmp?: number;
        iridAmp?: number;
        haloAmp?: number;
      }
    ) => { destroy: () => void } | null;
  }
}

function loadScriptOnce(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`) as HTMLScriptElement | null;
    if (existing) {
      if (existing.dataset.loaded === "true") {
        resolve();
        return;
      }
      existing.addEventListener("load", () => resolve(), { once: true });
      existing.addEventListener("error", () => reject(new Error(`Failed to load ${src}`)), {
        once: true,
      });
      return;
    }
    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.onload = () => {
      script.dataset.loaded = "true";
      resolve();
    };
    script.onerror = () => reject(new Error(`Failed to load ${src}`));
    document.head.appendChild(script);
  });
}

export function OrbHero() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [shaderReady, setShaderReady] = useState(false);

  useEffect(() => {
    let instance: { destroy: () => void } | null = null;
    let cancelled = false;

    async function boot() {
      try {
        await loadScriptOnce("/orb_assets.js");
        await loadScriptOnce("/orb_shader.js");
        if (cancelled || !canvasRef.current || !window.initOrbShaderCanvas) return;
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const size = Math.round(256 * dpr);
        instance = window.initOrbShaderCanvas(canvasRef.current, {
          width: size,
          height: size,
          radius: 0.308,
          speed: 2.15,
          flowAmp: 2.35,
          metalAmp: 1.50,
          relightAmp: 2.15,
          iridAmp: 2.05,
        });
        if (instance) {
          setShaderReady(true);
        }
      } catch {
        // Fallback image stays visible if WebGL2 fails
      }
    }

    boot();

    return () => {
      cancelled = true;
      instance?.destroy();
    };
  }, []);

  return (
    <div className="orb-hero-banner">
      <div className="orb-hero-visual" aria-hidden="true">
        <div className="orb-shader-stage">
          <img
            src="/images/orb-icon.png"
            alt="Orb App Icon"
            className={`orb-shader-fallback ${shaderReady ? "is-hidden" : ""}`}
          />
          <canvas
            ref={canvasRef}
            width={512}
            height={512}
            className={`orb-shader-canvas ${shaderReady ? "is-ready" : ""}`}
          />
          <img
            src="/images/orb-squircle-frame.png"
            alt=""
            className={`orb-shader-squircle-frame ${shaderReady ? "is-ready" : ""}`}
          />
        </div>
      </div>

      <div className="orb-hero-copy">
        <h1 className="orb-hero-title">
          All your AI providers, machines, and agent harnesses in one place.
        </h1>
        <p className="orb-hero-lead">
          Connect your subscriptions, API keys, and local hardware to your machines, and
          orchestrate <strong>Claude Code</strong>, <strong>Codex</strong>,{" "}
          <strong>Antigravity</strong>, <strong>OpenCode</strong>, and{" "}
          <strong>Grok</strong> from macOS and iOS. Formerly <code>sandboxed.sh</code>,
          which is now the backend to the Orb clients.
        </p>
        <div className="orb-hero-actions">
          <Link href="/getting-started" className="orb-btn orb-btn-primary">
            Get Started
          </Link>
          <Link href="/workspaces" className="orb-btn orb-btn-secondary">
            Workspaces
          </Link>
          <a
            href="https://github.com/Th0rgal/orb"
            target="_blank"
            rel="noreferrer"
            className="orb-btn orb-btn-ghost"
          >
            GitHub ↗
          </a>
        </div>
        <p className="orb-hero-ai-note">
          AI agent? Read <a href="/llms.txt"><code>/llms.txt</code></a> or append{" "}
          <code>.md</code> to any URL.
        </p>
      </div>
    </div>
  );
}
