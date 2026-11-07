/**
 * Orb Desktop native bridge (`window.__ORB_DESKTOP__`, with backwards-compatible
 * fallback to `window.__TAURI__` / `window.__TAURI_INTERNALS__` for tests and
 * older local shells). Browser previews have neither.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type NativeInvoke = <T = any>(command: string, args?: any, options?: { headers?: Record<string, string> }) => Promise<T>;

export type DesktopHostHandle = {
  core?: {
    invoke?: NativeInvoke;
    Channel?: new <T>() => { onmessage: (value: T) => void };
  };
  event?: {
    listen: <T>(
      name: string,
      handler: (event: { payload: T }) => void,
      options?: { target: { kind: string; label: string } },
    ) => Promise<() => void>;
  };
  window?: {
    getCurrentWindow?: () => {
      innerSize: () => Promise<{ width: number; height: number }>;
      scaleFactor: () => Promise<number>;
    };
  };
  webview?: {
    getCurrentWebview?: () => { label: string };
  };
};

type Host = {
  __ORB_DESKTOP__?: DesktopHostHandle;
  __TAURI_INTERNALS__?: { invoke?: NativeInvoke };
  __TAURI__?: DesktopHostHandle;
};
const host = (): Host | undefined => (typeof window === "undefined" ? undefined : (window as unknown as Host));

export function desktopHost(): DesktopHostHandle | undefined {
  const h = host();
  return h?.__ORB_DESKTOP__ ?? h?.__TAURI__;
}

export function nativeInvoke(): NativeInvoke | undefined {
  const h = host();
  return h?.__ORB_DESKTOP__?.core?.invoke ?? h?.__TAURI__?.core?.invoke ?? h?.__TAURI_INTERNALS__?.invoke;
}

/** Invoke a native command, or reject with `unavailable` outside the desktop app. */
export function invokeNative<T = unknown>(command: string, args: Record<string, unknown>, unavailable: string): Promise<T> {
  const invoke = nativeInvoke();
  return invoke ? invoke<T>(command, args) : Promise.reject(new Error(unavailable));
}

export const nativeChannel = () => desktopHost()?.core?.Channel;
export const nativeEvents = () => desktopHost()?.event;
export const nativeWindow = () => desktopHost()?.window?.getCurrentWindow?.();
export const nativeWebview = () => desktopHost()?.webview?.getCurrentWebview?.();
