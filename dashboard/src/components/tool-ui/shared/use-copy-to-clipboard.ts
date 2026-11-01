"use client";

import { useCallback, useEffect, useState } from "react";

function fallbackCopyToClipboard(text: string): boolean {
  const textArea = document.createElement("textarea");
  try {
    textArea.value = text;
    textArea.setAttribute("readonly", "");
    textArea.style.position = "fixed";
    textArea.style.top = "-9999px";
    textArea.style.left = "-9999px";
    document.body.appendChild(textArea);
    textArea.select();
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    textArea.remove();
  }
}

export function useCopyToClipboard(options?: {
  resetAfterMs?: number;
}): {
  copiedId: string | null;
  copy: (text: string, id?: string) => Promise<boolean>;
} {
  const resetAfterMs = options?.resetAfterMs ?? 2000;
  const [copied, setCopied] = useState<{ id: string } | null>(null);
  const copiedId = copied?.id ?? null;

  const copy = useCallback(
    async (text: string, id: string = "default") => {
      let ok = false;
      try {
        if (navigator.clipboard?.writeText) {
          await navigator.clipboard.writeText(text);
          ok = true;
        } else {
          ok = fallbackCopyToClipboard(text);
        }
      } catch {
        ok = fallbackCopyToClipboard(text);
      }

      if (ok) {
        setCopied({ id });
      }

      return ok;
    },
    [],
  );

  useEffect(() => {
    if (!copied) return;
    const timeout = setTimeout(() => setCopied(null), resetAfterMs);
    return () => clearTimeout(timeout);
  }, [copied, resetAfterMs]);

  return { copiedId, copy };
}

