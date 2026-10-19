/**
 * The Tauri bridge, when this page runs inside Orb desktop. `withGlobalTauri`
 * exposes both `__TAURI__.core.invoke` and `__TAURI_INTERNALS__.invoke`; the
 * browser preview has neither.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type NativeInvoke = <T = any>(command: string, args?: any, options?: { headers?: Record<string, string> }) => Promise<T>;

type Host = {
  __TAURI_INTERNALS__?: { invoke?: NativeInvoke };
  __TAURI__?: { core?: { invoke?: NativeInvoke; Channel?: new <T>() => { onmessage: (value: T) => void } }; event?: { listen: <T>(name: string, handler: (event: { payload: T }) => void) => Promise<() => void> } };
};
const host = (): Host | undefined => (typeof window === "undefined" ? undefined : (window as unknown as Host));

export function nativeInvoke(): NativeInvoke | undefined {
  const h = host();
  return h?.__TAURI__?.core?.invoke ?? h?.__TAURI_INTERNALS__?.invoke;
}

/** Invoke a native command, or reject with `unavailable` outside the desktop app. */
export function invokeNative<T = unknown>(command: string, args: Record<string, unknown>, unavailable: string): Promise<T> {
  const invoke = nativeInvoke();
  return invoke ? invoke<T>(command, args) : Promise.reject(new Error(unavailable));
}

export const nativeChannel = () => host()?.__TAURI__?.core?.Channel;
export const nativeEvents = () => host()?.__TAURI__?.event;
