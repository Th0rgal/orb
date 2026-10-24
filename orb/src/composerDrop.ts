import { onCleanup, onMount } from 'solid-js';
import { folderOfferSources, type FolderOffer, type UploadSource } from './uploads';

/** `folder` offers files found inside dropped folders (relative to the folder's parent). */
type Drop = { paths: string[]; folder?: FolderOffer; x: number; y: number };
type NativeDrop = { paths: string[]; position: { x: number; y: number } };

// Wry's macOS drag positions are window points, despite Tauri's PhysicalPosition
// type. Dividing those by Retina DPR moves the hit target outside the composer.
/** Native drops carry OS paths; only the composer under the pointer consumes them. */
export function nativeComposerDrop(element: () => HTMLElement | undefined, attach: (sources: UploadSource[],target:HTMLElement) => Promise<void>, targetAt?: (x:number,y:number)=>HTMLElement|undefined) {
  const disposers: (() => void)[] = [];
  let stopped = false, highlighted:HTMLElement|undefined;
  let deferred: { x: number; y: number; drop: Drop; timer: ReturnType<typeof setTimeout> } | undefined;
  let relayed: { x: number; y: number; time: number } | undefined;
  // Current binaries emit both events for one drop; only Orb's relay carries the
  // files inside dropped folders. Hold the generic event briefly and let the relay win.
  const consume = (drop: Drop, channel: string) => {
    if (channel === 'orb') {
      if (deferred && deferred.x === drop.x && deferred.y === drop.y) { clearTimeout(deferred.timer); deferred = undefined; }
      relayed = { x: drop.x, y: drop.y, time: Date.now() };
      apply(drop);
      return;
    }
    if (relayed && relayed.x === drop.x && relayed.y === drop.y && Date.now() - relayed.time < 1000) return;
    if (deferred) { clearTimeout(deferred.timer); apply(deferred.drop); }
    deferred = { x: drop.x, y: drop.y, drop, timer: setTimeout(() => { deferred = undefined; apply(drop); }, 120) };
  };
  const apply = ({ paths, folder, x, y }: Drop) => {
    const scale = /^Mac/.test(navigator.platform) ? 1 : (window.devicePixelRatio || 1);
    const el = targetAt?targetAt(x/scale,y/scale):element();
    highlighted?.classList.remove('drop-active');
    el?.classList.remove('drop-active');
    if (stopped || !el || !el.getClientRects().length || (!paths.length && !folder?.files.length) || !Number.isFinite(x) || !Number.isFinite(y)) return;
    const bounds = el.getBoundingClientRect();
    if (x / scale < bounds.left || x / scale > bounds.right || y / scale < bounds.top || y / scale > bounds.bottom) return;
    const name = (path: string) => path.split(/[\\/]/).at(-1) ?? 'file';
    void attach([...paths.map(path => ({ name: name(path), localPath: path })), ...folderOfferSources(folder)],el);
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
  onCleanup(() => { stopped = true; if (deferred) clearTimeout(deferred.timer); disposers.forEach(off => off()); });
}
