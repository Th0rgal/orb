import { onCleanup, onMount } from 'solid-js';
import type { UploadSource } from './uploads';

type Drop = { paths: string[]; x: number; y: number };
type NativeDrop = { paths: string[]; position: { x: number; y: number } };

// Wry's macOS drag positions are window points, despite Tauri's PhysicalPosition
// type. Dividing those by Retina DPR moves the hit target outside the composer.
/** Native drops carry OS paths; only the composer under the pointer consumes them. */
export function nativeComposerDrop(element: () => HTMLElement | undefined, attach: (sources: UploadSource[],target:HTMLElement) => Promise<void>, targetAt?: (x:number,y:number)=>HTMLElement|undefined) {
  const disposers: (() => void)[] = [];
  let stopped = false, highlighted:HTMLElement|undefined;
  let previous: { signature: string; time: number; channel: string } | undefined;
  const consume = ({ paths, x, y }: Drop, channel: string) => {
    const scale = /^Mac/.test(navigator.platform) ? 1 : (window.devicePixelRatio || 1);
    const el = targetAt?targetAt(x/scale,y/scale):element();
    highlighted?.classList.remove('drop-active');
    el?.classList.remove('drop-active');
    if (stopped || !el || !el.getClientRects().length || !paths.length || !Number.isFinite(x) || !Number.isFinite(y)) return;
    const bounds = el.getBoundingClientRect();
    if (x / scale < bounds.left || x / scale > bounds.right || y / scale < bounds.top || y / scale > bounds.bottom) return;
    const signature = JSON.stringify([paths, x, y]), time = Date.now();
    // Current binaries emit both events. Repeated drops on the same channel
    // remain separate user actions.
    if (previous?.signature === signature && previous.channel !== channel && time - previous.time < 250) return;
    previous = { signature, time, channel };
    void attach(paths.map(path => ({ name: path.split(/[\\/]/).at(-1) ?? 'file', localPath: path })),el);
  };
  onMount(() => {
    const native = (window as any).__TAURI__;
    const events = native?.event;
    if (!events) return;
    const listen = (name: string, handler: (event: any) => void, options?: { target: { kind: string; label: string } }) => {
      void events.listen(name, handler, options).then((off: () => void) => {
        if (stopped) off(); else disposers.push(off);
      });
    };
    const highlight = ({ payload }: { payload: NativeDrop }) => {
      highlighted?.classList.remove('drop-active');
      const scale = /^Mac/.test(navigator.platform) ? 1 : (window.devicePixelRatio || 1);
      const x = payload.position.x / scale, y = payload.position.y / scale;
      const el=targetAt?targetAt(x,y):element();highlighted=el;if(!el)return;
      const bounds=el.getBoundingClientRect();
      el.classList.toggle('drop-active', x >= bounds.left && x <= bounds.right && y >= bounds.top && y <= bounds.bottom);
    };
    const target = { target: { kind: 'Webview', label: native.webview?.getCurrentWebview?.().label ?? 'main' } };
    listen('tauri://drag-enter', highlight, target);
    listen('tauri://drag-over', highlight, target);
    listen('tauri://drag-leave', () => highlighted?.classList.remove('drop-active'), target);
    listen('orb-upload-drop', ({ payload }: { payload: Drop }) => consume(payload, 'orb'));
    // Also works with already-running desktop binaries without Orb's custom relay.
    listen('tauri://drag-drop', ({ payload }: { payload: NativeDrop }) => {
      consume({ paths: payload.paths, ...payload.position }, 'tauri');
    }, { target: { kind: 'Webview', label: native.webview?.getCurrentWebview?.().label ?? 'main' } });
  });
  onCleanup(() => { stopped = true; disposers.forEach(off => off()); });
}
