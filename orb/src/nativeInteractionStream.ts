/** Ordered native snapshot and changes. Disposal also handles late registration. */
export function followNative<T>(command: string, args: Record<string, unknown>, publish: (value: T) => void, fail: (error: unknown) => void): () => void {
  const host = window as unknown as {
    __TAURI_INTERNALS__?: { invoke: (command: string, args: Record<string, unknown>) => Promise<unknown> };
    __TAURI__?: { core?: { invoke?: (command:string,args:Record<string,unknown>)=>Promise<unknown>; Channel?: new () => { onmessage: (value: T) => void } } };
  };
  const invoke = host.__TAURI_INTERNALS__?.invoke ?? host.__TAURI__?.core?.invoke, Channel = host.__TAURI__?.core?.Channel;
  let stopped = false, token: number | undefined;
  const unsubscribe = (token: number) => void invoke?.(`${command}_unsubscribe`, {...args, token}).catch(fail);
  if (!invoke || !Channel) { queueMicrotask(() => { if (!stopped) fail(new Error('Native event transport unavailable.')); }); }
  else {
    const channel = new Channel();
    channel.onmessage = value => { if (!stopped) publish(value); };
    void invoke(`${command}_subscribe`, {...args, onEvent: channel}).then(value => {
      token = value as number;
      if (stopped) unsubscribe(token);
    }).catch(error => { if (!stopped) fail(error); });
  }
  return () => { if (stopped) return; stopped = true; if (token !== undefined) unsubscribe(token); };
}
export const followInteraction = <T>(id: string, publish: (value: T | null) => void, fail: (error: unknown) => void) =>
  followNative('local_interaction', {id}, publish, fail);
