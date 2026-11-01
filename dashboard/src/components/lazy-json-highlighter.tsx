"use client";

import { useState, useEffect, memo } from "react";
import type { CSSProperties } from "react";

/**
 * A JSON code block that shows plain monospace text immediately and
 * lazy-loads SyntaxHighlighter after mount. This avoids the ~200-800ms
 * synchronous Prism tokenization that blocks the main thread when
 * expanding tool calls. See issue #156.
 */

// Lazy-loaded module — only fetched on first render of a highlighted block.
let highlighterModulePromise: Promise<{
  Highlighter: typeof import("react-syntax-highlighter").default;
  darkTheme: Record<string, CSSProperties>;
  lightTheme: Record<string, CSSProperties>;
}> | null = null;

function getHighlighterModule() {
  if (!highlighterModulePromise) {
    highlighterModulePromise = Promise.all([
      import("react-syntax-highlighter").then((m) => m.Prism),
      import("react-syntax-highlighter/dist/esm/styles/prism").then(
        (m) => m.oneDark
      ),
      import("react-syntax-highlighter/dist/esm/styles/prism").then(
        (m) => m.oneLight
      ),
    ]).then(([Highlighter, darkTheme, lightTheme]) => ({
      Highlighter,
      darkTheme,
      lightTheme,
    })).catch((error) => {
      // A transient chunk download failure must not poison future mounts.
      highlighterModulePromise = null;
      throw error;
    });
  }
  return highlighterModulePromise;
}

interface LazyJsonHighlighterProps {
  children: string;
  background?: string;
  textColor?: string;
}

export const LazyJsonHighlighter = memo(function LazyJsonHighlighter({
  children,
  background = "rgb(var(--code-background))",
  textColor,
}: LazyJsonHighlighterProps) {
  const [Loaded, setLoaded] = useState<{
    Highlighter: typeof import("react-syntax-highlighter").default;
    darkTheme: Record<string, CSSProperties>;
    lightTheme: Record<string, CSSProperties>;
  } | null>(null);
  const [isLight, setIsLight] = useState(false);

  useEffect(() => {
    let cancelled = false;
    getHighlighterModule().then(
      (mod) => { if (!cancelled) setLoaded(mod); },
      () => { /* Keep the readable plain-text fallback if loading fails. */ },
    );
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const query = window.matchMedia("(prefers-color-scheme: light)");
    const update = () => {
      const theme = document.documentElement.dataset.theme;
      setIsLight(theme ? theme === "light" : query.matches);
    };
    update();
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    query.addEventListener("change", update);
    return () => {
      observer.disconnect();
      query.removeEventListener("change", update);
    };
  }, []);

  const monoFont =
    'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace';

  // Before the highlighter loads, show plain monospace text. This renders
  // in <1ms vs 200-800ms for SyntaxHighlighter, making expand feel instant.
  if (!Loaded) {
    return (
      <pre
        style={{
          margin: 0,
          padding: "0.5rem",
          fontSize: "0.75rem",
          borderRadius: "0.25rem",
          background,
          color: textColor ?? "rgb(var(--code-foreground))",
          border: "1px solid rgb(var(--code-border) / 0.08)",
          fontFamily: monoFont,
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          overflow: "hidden",
        }}
      >
        {children}
      </pre>
    );
  }

  const { Highlighter, darkTheme, lightTheme } = Loaded;
  return (
    <Highlighter
      language="json"
      style={isLight ? lightTheme : darkTheme}
      customStyle={{
        margin: 0,
        padding: "0.5rem",
        fontSize: "0.75rem",
        borderRadius: "0.25rem",
        background,
        border: "1px solid rgb(var(--code-border) / 0.08)",
      }}
      codeTagProps={{
        style: {
          fontFamily: monoFont,
          color: textColor,
        },
      }}
    >
      {children}
    </Highlighter>
  );
});
