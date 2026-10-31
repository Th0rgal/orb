import { swallow } from "../log";
import {CodexSpeedPicker} from '../CodexSpeedPicker';
import { Picker } from "../Picker";
import { Menu } from "../Menu";
import { Popover } from "../Popover";
import { CyberPicker, draftCyber, setDraftCyber } from "../cyberAccess";
import {MentionPicker} from "../MentionPicker";
import { nativeComposerDrop } from "../composerDrop";
import { backgroundUploads, cancelBackgroundUpload, encoded, formatFileSize, HARD_MAX_BYTES, hasNativePicker, pauseBackgroundUpload, pickNativeFiles, pickNativeFolder, grantFolderSources, prepareUploads, resumeBackgroundUpload, softLimitForDestination, startBackgroundUpload, statUploadSource, transferFile, uploadToken, type UploadedFile, type UploadSource } from "../uploads";
import { readComposerDraft, saveComposerDraft } from "../composerDrafts";
import { BATCH_MAX_BYTES, BATCH_MAX_FILES, BATCH_WARN_BYTES, BATCH_WARN_FILES, batchTotals, createFolderUpload, localFolderPath, folderPathFromResults, sourcesFromDataTransfer, splitSources, type FolderUpload } from "../uploadBatch";
import { FolderUploadChip } from "./FolderUploadChip";
import { readImagePaste, IMAGE_COUNT, type DraftImage } from "../imageAttachments";
import { ErrorToast } from "../toast";
import { type RemoteSupport } from "../missionLaunch";
import { absorbGoalPrefix, composerModes, filterSlash, slashQuery, modePrompt, ModeChip, type ComposerMode } from "../goal";
import { atQuery, browseAttachItems, filterAttach, folderPrefixFromQuery, insertMention, loadAttachItems, mentionedChips, type AttachChip, type AttachItem } from "../attach";
import { hasOverlay } from "../overlayLayer";
import { Lightbox } from "../Lightbox";
import { For, Show, createMemo, createSignal, createEffect, on, onCleanup, onMount } from "solid-js";
import type { JSX } from "solid-js";
import * as Ic from "../icons";
import { defaultEffortLabel, effortLabel, harnessSupportsEffort, normalizeEffort, supportedEfforts } from "../effort";
import { VoiceButton, ensureVoiceProbe, voiceAvailable } from "../VoiceButton";
import { insertAtCaret } from "../voice";
import {
  localInstalled,
  refreshLocalAgents,
} from "../localAgents";
import {
  isConnected,
  shortModelLabel,
  connectionVersion,
  getApiUrl,
} from "../api";

import { harnessChoices, setHarnessPick, effectivePick, refreshHarnessChoices, refreshNodeAntigravityModels } from "../harnessPick";

const MODELS = ["Orb Lorem 4.6 High Fast", "Ipsum 5 Max", "Dolor 4.5 Sonnet", "Auto"];

export const draftLightbox = (images: DraftImage[]) => images.map((image, index) => ({ src: image.dataUrl, label: image.reference ? `Image #${image.reference}` : `Image ${index + 1}` }));

function OptimisticMessage(p: {draft:{text:string; images:DraftImage[]}}) {
  const [viewing,setViewing]=createSignal<number|null>(null);
  return <div class="optimistic-message" aria-label="Pending message"><div class="user"><Show when={p.draft.images.length}><div class="message-images"><For each={p.draft.images}>{(image,index)=><button type="button" class="message-image" aria-label={`Open image #${image.reference ?? index()+1}`} onClick={()=>setViewing(index())}><img src={image.dataUrl} alt={`Image #${image.reference ?? index()+1}`}/><span>#{image.reference ?? index()+1}</span></button>}</For></div></Show><Show when={viewing()!==null}><Lightbox items={draftLightbox(p.draft.images)} index={viewing()!} onClose={()=>setViewing(null)}/></Show><span>{p.draft.text}</span></div><span class="composer-pending-status" role="status">Waiting for confirmation…</span></div>;
}

export function Composer(p: {
  revision?: { text: string; append?: boolean };
  onBtw?: (question: string, images?: DraftImage[], files?: UploadedFile[]) => boolean | Promise<boolean>;
  sideQuestion?: boolean;
  onOpenBtw?: () => void;
  placeholder: string;
  busy: boolean;
  onSend: (t: string, images: DraftImage[], files?: UploadedFile[]) => void | boolean | Promise<void | boolean>;
  onStop?: () => void;
  textOnly?: boolean;
  imagesOnly?: boolean;
  directFileUpload?: boolean;
  controls?: JSX.Element;
  disabled?: boolean;
  autofocus?: boolean;
  tall?: boolean;
  /** Show the harness + model picker (new agents only). */
  picker?: boolean;
  /** Conversation identity; dictation results for another scope are dropped. */
  scope?: string;
  /** Server-confirmed remote support for a harness on the selected machine (new agents only). */
  remoteSupport?: (backend: string) => { state: RemoteSupport; note: string };
  /** When set, the harness menu only lists these ids (This computer). */
  harnessIds?: string[];
  /** Follow-up: the mission's harness. New agent uses the picker. */
  backend?: string;
  onDraft?: (text: string) => void;
  onPending?: (draft: {text:string; images:DraftImage[]; retry?:()=>void} | null) => void;
  onSendError?: (error:string)=>void;
  retainFailedMessage?:boolean;
  projectSlug?: string;
  /** Reports what the draft currently mentions; the draft text is the source. */
  onAttachments?: (next: AttachChip[]) => void;
  uploadTarget?: string;
  /** Editing a queued follow-up in place: shows the chip, × cancels. */
  editingQueued?: { onCancel: () => void };
  /** Enter on an empty draft (e.g. send the queued follow-ups now). */
  onEmptySubmit?: () => void;
  /** Right arrow on an empty draft edits the first queued message. */
  onEditFirstQueued?: () => void;
  /** Allow typing and stacking follow-up messages while an earlier send is in flight. */
  allowConcurrentSend?: boolean;
  /** Accessible name of the draft field (defaults to the placeholder). */
  inputLabel?: string;
  /** Title and accessible name of the send button. */
  sendLabel?: string;
  /** With textOnly: keep "+" in place, disabled, explaining why attachments are unavailable. */
  attachDisabledReason?: string;
}) {
  const [text, setText] = createSignal("");
  const [uploading, setUploading] = createSignal(false);
  const [uploadError, setUploadError] = createSignal<string | null>(null);
  const [pendingLargeUploads, setPendingLargeUploads] = createSignal<Array<{ source: UploadSource; size: number; destination: string }>>([]);
  let uploaded: UploadedFile[] = [];
  const [uploadTick, bumpUploads] = createSignal(0);
  let disposed = false;
  onCleanup(() => { disposed = true; });
  let fileInput!: HTMLInputElement;
  const uploadTarget = () => p.uploadTarget ?? "core";
  const attachmentTarget = () => uploadTarget();
  const insertUploadedFile = (file: UploadedFile) => {
    uploaded.push(file); bumpUploads(n => n + 1);
    const current = ta ? (ta.selectionStart ?? text().length) : text().length;
    const token = uploadToken(file.path) + " ";
    const next = insertAtCaret(text(), current, ta ? (ta.selectionEnd ?? current) : current, token);
    write(next.value); setCaret(next.caret); ta?.setSelectionRange(next.caret, next.caret);
  };
  const confirmLargeUploads = () => {
    const items = pendingLargeUploads();
    setPendingLargeUploads([]);
    const scopeKey = p.scope ?? "new";
    for (const item of items) {
      startBackgroundUpload({
        source: item.source,
        destination: item.destination,
        totalBytes: item.size,
        confirmedLarge: true,
        scope: scopeKey,
        onComplete: (file) => {
          if (!disposed) insertUploadedFile(file);
        },
      });
    }
  };
  const scopedBgUploads = createMemo(() => {
    const scopeKey = p.scope ?? "new";
    return backgroundUploads().filter((item) => item.scope === scopeKey && (item.state === "uploading" || item.state === "paused" || item.state === "failed"));
  });
  const attachSources = async (sources: UploadSource[]) => {
    if (p.textOnly && p.attachDisabledReason && sources.length) { setUploadError(p.attachDisabledReason); return; }
    if (p.textOnly || p.imagesOnly) return;
    const scope = p.scope;
    const destination = attachmentTarget();
    const softLimit = softLimitForDestination(destination);
    const split = splitSources(sources, destination);
    for (const folder of split.folders) void attachFolder(folder.root, folder.sources, split.skipped);
    sources = split.files;
    if (!sources.length) return;
    setUploading(true); setUploadError(null); setCtx(false); setStaleFiles([]);
    try {
      const largeQueue: Array<{ source: UploadSource; size: number; destination: string }> = [];
      const ready: UploadSource[] = [];
      for (const source of sources) {
        if (disposed || scope !== p.scope || destination !== attachmentTarget()) return;
        const stat = await statUploadSource(source);
        if (stat.size > HARD_MAX_BYTES) {
          throw new Error(`${source.name} (${formatFileSize(stat.size)}) exceeds the 2 GiB maximum.`);
        }
        if (stat.size > softLimit) largeQueue.push({ source, size: stat.size, destination });
        else ready.push(source);
      }
      // Up to four transfers at once; mentions are inserted in the order chosen.
      const results: Array<UploadedFile | Error> = new Array(ready.length);
      let cursor = 0;
      await Promise.all(Array.from({ length: Math.min(4, ready.length) }, async () => {
        while (cursor < ready.length) {
          const index = cursor++;
          results[index] = await transferFile(ready[index], destination).catch(error => error instanceof Error ? error : new Error(String(error)));
        }
      }));
      if (disposed || scope !== p.scope || destination !== attachmentTarget()) return;
      const failures: string[] = [];
      results.forEach((result, index) => { if (result instanceof Error) failures.push(`${ready[index].name}: ${result.message}`); else insertUploadedFile(result); });
      if (failures.length) throw new Error(failures.length === 1 && ready.length === 1 ? failures[0].slice(ready[0].name.length + 2) : failures.join("\n"));
      if (largeQueue.length) {
        setPendingLargeUploads((prev) => [...prev, ...largeQueue]);
      }
    } catch (error) { const message=error instanceof Error ? error.message : String(error);setUploadError(message);p.onSendError?.(message); }
    finally { setUploading(false); }
  };
  // Folder uploads: one chip per folder, one mention once every file landed.
  const [folderUploads, setFolderUploads] = createSignal<FolderUpload[]>([]);
  onCleanup(() => folderUploads().forEach(upload => { upload.cancel(); revokes.get(upload)?.(); }));
  const [pendingFolder, setPendingFolder] = createSignal<{ root: string; files: Array<{ source: UploadSource; size: number }>; skipped: number; destination: string } | null>(null);
  /** Names of attachments whose original file is gone; their mentions were removed from the draft. */
  const [staleFiles, setStaleFiles] = createSignal<string[]>([]);
  const folderBusy = () => folderUploads().some(upload => upload.batch.running);
  const insertFolder = (root: string, path: string, count: number, bytes: number, files: string[], destination: string) =>
    insertUploadedFile({ source: { name: root }, path, destination, connection: connectionVersion(), endpoint: getApiUrl(), folder: { name: root, count, bytes, files } });
  const attachFolder = async (root: string, sources: UploadSource[], skipped: number) => {
    const destination = attachmentTarget();
    if (destination === "side") { setUploadError("Side questions take files, not folders. Attach the files you need."); return; }
    if (sources.length > BATCH_MAX_FILES) { setUploadError(`${root} has more than ${BATCH_MAX_FILES} files. Attach a smaller folder.`); return; }
    if (destination === "local") {
      const path = localFolderPath(sources);
      if (path) { insertFolder(root, path, sources.length, 0, sources.map(source => source.relativePath ?? source.name), destination); return; }
    }
    try {
      const files: Array<{ source: UploadSource; size: number }> = [];
      for (const source of sources) files.push({ source, size: source.size ?? (await statUploadSource(source)).size });
      const bytes = files.reduce((sum, file) => sum + file.size, 0);
      if (bytes > BATCH_MAX_BYTES) { setUploadError(`${root} is ${formatFileSize(bytes)}; folders can be up to ${formatFileSize(BATCH_MAX_BYTES)}.`); return; }
      const request = { root, files, skipped, destination };
      if (files.length > BATCH_WARN_FILES || bytes > BATCH_WARN_BYTES) setPendingFolder(request);
      else await startFolder(request);
    } catch (error) { setUploadError(error instanceof Error ? error.message : String(error)); }
  };
  const revokes = new Map<FolderUpload, () => void>();
  const startFolder = async (request: { root: string; files: Array<{ source: UploadSource; size: number }>; skipped: number; destination: string }) => {
    const scope = p.scope;
    let revoke: () => void;
    // Only now, after any confirmation, may the desktop read these files.
    try { revoke = await grantFolderSources(request.files.map(file => file.source)); }
    catch (error) { setUploadError(error instanceof Error ? error.message : String(error)); return; }
    if (disposed || scope !== p.scope) { revoke(); return; }
    const upload = createFolderUpload({ ...request, transfer: transferFile });
    revokes.set(upload, revoke);
    setFolderUploads(list => [...list, upload]);
    void runFolder(upload, scope);
  };
  const dropFolder = (upload: FolderUpload) => {
    revokes.get(upload)?.(); revokes.delete(upload);
    setFolderUploads(list => list.filter(item => item !== upload));
  };
  const runFolder = async (upload: FolderUpload, scope = p.scope) => {
    await upload.run();
    if (disposed || scope !== p.scope || upload.batch.cancelled || upload.batch.destination !== attachmentTarget()) return;
    const totals = batchTotals(upload.batch);
    if (totals.failed) return; // The chip offers Retry or Skip.
    finishFolder(upload);
  };
  const finishFolder = (upload: FolderUpload) => {
    const done = upload.batch.files.filter(file => file.state === "done" && file.result);
    dropFolder(upload);
    if (!done.length) return;
    const path = folderPathFromResults(done.map(file => ({ relativePath: file.source.relativePath!, path: file.result!.path })));
    if (path) insertFolder(upload.batch.root, path, done.length, done.reduce((sum, file) => sum + file.size, 0), done.map(file => file.source.relativePath!), upload.batch.destination);
    else for (const file of done) insertUploadedFile(file.result!); // The machine flattened the tree (older node).
  };
  let composerElement:HTMLDivElement|undefined;
  nativeComposerDrop(()=>composerElement, async sources=>{
    if(sendingLocked()||uploading()||readingImages()) { setUploadError("Please wait for the current attachment or message to finish, then drop your files again."); return; }
    if (p.imagesOnly || p.directFileUpload) await attachMixed(sources);
    else await attachSources(sources);
  });
  const attachMixed = async (sources: UploadSource[]) => {
    // Never drop files silently: say why this destination can't take them.
    if (p.textOnly) { if (p.attachDisabledReason && sources.length) setUploadError(p.attachDisabledReason); return; }
    try {
    const scope=p.scope;
    sources=await Promise.all(sources.map(async source=>{
      const mime:Record<string,string>={png:"image/png",jpg:"image/jpeg",jpeg:"image/jpeg",webp:"image/webp",gif:"image/gif"};
      const type=mime[source.name.split('.').at(-1)?.toLowerCase()??''];
      if(!source.file&&source.localPath&&type){
        const bytes=Uint8Array.from(atob(await encoded(source)),c=>c.charCodeAt(0));
        return {...source,file:new File([bytes],source.name,{type})};
      }
      return source;
    }));
    if(disposed||scope!==p.scope)return;
    const pictures = sources.filter(source => source.file?.type.startsWith("image/"));
    if (pictures.length) {
      const clipboard = { files: pictures.map(source=>source.file!), getData:()=>"" };
      await pasteImages({clipboardData:clipboard,preventDefault(){}} as unknown as ClipboardEvent);
    }
    const files = sources.filter(source => !pictures.includes(source));
    if (files.length && !p.imagesOnly) await attachSources(files);
    else if (files.length && p.imagesOnly) setImageError("Use a PNG, JPEG, WebP or GIF image.");
    } catch(error){setUploadError(error instanceof Error?error.message:String(error));}
  };
  const chooseFiles = async () => {
    setCtx(false); setUploadError(null);
    if (p.imagesOnly || p.directFileUpload || !hasNativePicker()) { fileInput.click(); return; }
    const scope = p.scope;
    const selection = uploadTarget();
    try { const files = await pickNativeFiles(); if (!disposed && scope === p.scope && selection === uploadTarget()) await attachMixed(files); }
    catch (error) { setUploadError(error instanceof Error ? error.message : String(error)); }
  };
  let folderInput!: HTMLInputElement;
  const chooseFolder = async () => {
    setCtx(false); setUploadError(null);
    if (!hasNativePicker()) { folderInput.click(); return; }
    const scope = p.scope;
    try { const files = await pickNativeFolder(); if (!disposed && scope === p.scope && files.length) await attachSources(files); }
    catch (error) { setUploadError(error instanceof Error ? error.message : String(error)); }
  };
  const [images, setImages] = createSignal<DraftImage[]>([]);
  // Direct uploads (cloud agents) show each file as a removable chip; the
  // draft's token stays the source of truth, as for mentions.
  const fileChips = createMemo(() => { uploadTick(); return [...uploaded]; });
  const removeUploadedFile = (file: UploadedFile) => {
    const token = uploadToken(file.path);
    uploaded = uploaded.filter(item => item !== file); bumpUploads(n => n + 1);
    const value = text().replaceAll(`${token} `, "").replaceAll(token, "");
    write(value); if (ta) { ta.value = value; resize(); }
  };
  const [viewing, setViewing] = createSignal<number | null>(null);
  const [sendingCount, setSendingCount] = createSignal(0);
  const sending = () => sendingCount() > 0;
  const sendingLocked = () => sending() && (!p.allowConcurrentSend || !!p.editingQueued);
  const [pendingSend, setPendingSend] = createSignal<{text:string; images:DraftImage[]} | null>(null);
  const [mode, setMode] = createSignal<ComposerMode | null>(null);
  const [draftReady, setDraftReady] = createSignal(false);
  createEffect(on(() => p.scope, (scope, previous) => {
    if (previous !== undefined && previous !== scope) { setText(""); setImages([]); setMode(null); uploaded = []; bumpUploads(n => n + 1); folderUploads().forEach(upload => { upload.cancel(); dropFolder(upload); }); setPendingFolder(null); setStaleFiles([]); }
    setDraftReady(false);
    if (!scope) { setDraftReady(true); return; }
    let current=true;
    onCleanup(() => {
      current=false;
      // A fast close can happen before hydration enables the persistence
      // effect. Flush typed content without clearing an untouched disk draft.
      if (draftReady() || text() || images().length || mode()) {
        void saveComposerDraft(scope,{text:pendingSend()?.text ?? text(),images:pendingSend()?.images ?? images(),mode:mode(),uploads:uploaded.map(file => ({...file, source:file.source}))}).catch(swallow("composer.saveDraft", { scope, phase: "close" }));
      }
    });
    void readComposerDraft(scope).then(draft => {
      if (current && draft && !text() && !images().length) {
        uploaded = (draft.uploads ?? []).map(file => ({...file, connection: file.endpoint === getApiUrl() ? connectionVersion() : -1})); bumpUploads(n => n + 1);
        setText(draft.text);setImages(draft.images);
        if(draft.mode) setMode(draft.mode);
        queueMicrotask(() => { if (ta?.isConnected) { ta.value=draft.text; resize(); } });
      }
    }).catch(swallow("composer.readDraft", { scope })).finally(() => { if (current) setDraftReady(true); });
  }));
  let draftTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingDraftSave: { scope: string; draft: Parameters<typeof saveComposerDraft>[1] } | null = null;
  const flushDraftSave = () => {
    if (draftTimer !== undefined) {
      clearTimeout(draftTimer);
      draftTimer = undefined;
    }
    if (pendingDraftSave) {
      const { scope, draft } = pendingDraftSave;
      pendingDraftSave = null;
      void saveComposerDraft(scope, draft).catch(swallow("composer.saveDraft", { scope }));
    }
  };
  onCleanup(flushDraftSave);
  createEffect(() => {
    const scope = p.scope;
    const ready = draftReady();
    const curText = pendingSend()?.text ?? text();
    const curImages = pendingSend()?.images ?? images();
    const curMode = mode();
    if (!ready || !scope) return;
    const draft = {
      text: curText,
      images: curImages,
      mode: curMode,
      uploads: uploaded.map((file) => ({ ...file, source: file.source })),
    };
    if (!curText && !curImages.length && !curMode) {
      pendingDraftSave = { scope, draft };
      flushDraftSave();
      return;
    }
    pendingDraftSave = { scope, draft };
    if (draftTimer !== undefined) clearTimeout(draftTimer);
    draftTimer = setTimeout(flushDraftSave, 180);
  });
  const [imageError, setImageError] = createSignal<string | null>(null);
  const [readingImages, setReadingImages] = createSignal(false);
  const pasteImages = async (event: ClipboardEvent) => {
    if (p.textOnly) {
      if (p.attachDisabledReason && Array.from(event.clipboardData?.files ?? []).length) { event.preventDefault(); setImageError(p.attachDisabledReason); }
      return;
    }
    const clipboard = event.clipboardData;
    if (!clipboard) return;
    const files = Array.from(clipboard.files).filter(file => file.type.startsWith("image/"));
    const html = clipboard.getData("text/html");
    const plain = clipboard.getData("text/plain");
    if (!files.length && !/<img\b|data-proton-embedded\s*=/i.test(html)) return;
    event.preventDefault();
    if (readingImages() || sendingLocked()) return;
    setImageError(null);
    const scope = p.scope;
    const original = text(), start = ta.selectionStart, end = ta.selectionEnd;
    setReadingImages(true);
    try {
      const first = Math.max(0, ...images().map(image => image.reference ?? 0)) + 1;
      const next = await readImagePaste(html, plain, files, first);
      if (disposed || scope !== p.scope) return;
      if (images().length + next.images.length > IMAGE_COUNT) throw new Error(`Attach up to ${IMAGE_COUNT} images at a time.`);
      // Do not overwrite edits made while an embedded image was loading.
      if (text() !== original) throw new Error("The draft changed while images loaded. Paste again to insert them at the cursor.");
      const value = original.slice(0, start) + next.text + original.slice(end);
      setImages(previous => [...previous, ...next.images]);
      setText(value); ta.value = value;
      ta.setSelectionRange(start + next.text.length, start + next.text.length);
      resize();
    } catch (e) { if (scope === p.scope) setImageError(e instanceof Error ? e.message : String(e)); }
    finally { setReadingImages(false); }
  };
  createEffect(on(() => p.scope, () => { setImages([]); setImageError(null); }, {defer:true}));
  // Local voice input (macOS): dictated text lands at the caret, never sends.
  const [voiceActive, setVoiceActive] = createSignal(false);
  ensureVoiceProbe();

  const [slashHi, setSlashHi] = createSignal(0);
  const [model, setModel] = createSignal(MODELS[0]);
  const live = () => isConnected() && harnessChoices(p.uploadTarget).length > 0;
  const [menu, setMenu] = createSignal(false);
  const [ctx, setCtx] = createSignal(false);
  const [which, setWhich] = createSignal<"harness" | "model" | "effort" | null>(null);
  const [slashOff, setSlashOff] = createSignal(false);
  const [atOff, setAtOff] = createSignal(false);
  const [atHi, setAtHi] = createSignal(0);
  const [atItems, setAtItems] = createSignal<AttachItem[]>([]);
  const [caret, setCaret] = createSignal(0);
  let ta!: HTMLTextAreaElement;
  const pick = () => effectivePick(p.uploadTarget);
  const backend = () => p.backend ?? pick()?.backend ?? null;
  // Restored local conversations can open before New Agent or Settings has
  // scanned installed harnesses. Load capabilities for their composer too.
  // Keyed by value: the parent rebuilds these props from each mission refresh,
  // and re-running on identical values refetched catalogs every few seconds.
  const harnessTarget = createMemo(() => p.uploadTarget);
  const projectSlug = createMemo(() => p.projectSlug);
  createEffect(() => {
    if (p.sideQuestion) return;
    const target = harnessTarget();
    if (target === "local") void refreshLocalAgents(false);
    else if (target && target !== "side") void refreshNodeAntigravityModels(target);
  });
  const modes = createMemo(() => p.textOnly || p.imagesOnly || p.sideQuestion ? [] : [...composerModes(backend(), p.uploadTarget === "local" ? !!localInstalled().find(h=>h.id===backend())?.plan_supported : !!p.uploadTarget && !!harnessChoices(p.uploadTarget).find(h=>h.backend.id===backend())?.backend.native_plan), ...(p.onBtw ? [{id:"btw" as const, section:"Modes" as const,label:"Side question",title:"Ask without interrupting the agent"}] : [])]);
  const slash = createMemo(() => {
    if (mode() || voiceActive() || slashOff()) return null;
    const q = slashQuery(text());
    if (!q.open) return null;
    const items = filterSlash(modes(), q.query);
    return items.length ? { query: q.query, items } : null;
  });
  const [ctxFolder, setCtxFolder] = createSignal("");
  const atSource = createMemo<AttachItem[]>(() => {
    return [...(p.sideQuestion || mode() === "btw" ? [{ id: "btw:conversation", kind: "context" as const, section: "Context" as const, path: "conversation", label: "conversation · Latest agent conversation" }] : []), ...(isConnected() ? atItems() : [])];
  });
  const at = createMemo(() => {
    if (p.textOnly || p.imagesOnly || voiceActive() || atOff() || slash()) return null;
    const q = atQuery(text(), caret());
    if (!q.open) return null;
    const source = atSource();
    const items = filterAttach(source, q.query);
    const folder = folderPrefixFromQuery(source, q.query) ?? "";
    return items.length ? { query: q.query, items, folder } : null;
  });
  const setAtFolder = (folder: string) => {
    const q = atQuery(text(), caret());
    if (!q.open || q.start < 0) return;
    const token = folder ? `@${folder.replace(/\/+$/, "")}/` : "@";
    const next = `${text().slice(0, q.start)}${token}${text().slice(caret())}`;
    const nextCaret = q.start + token.length;
    write(next);
    setAtOff(false);
    ta.focus();
    ta.setSelectionRange(nextCaret, nextCaret);
    setCaret(nextCaret);
  };
  createEffect(() => {
    slash();
    setSlashHi(0);
  });
  createEffect(() => {
    at();
    setAtHi(0);
  });
  let attachmentLoad: Promise<void> = Promise.resolve();
  createEffect(() => {
    const slug = projectSlug();
    if (!slug || !isConnected()) {
      setAtItems([]);
      return;
    }
    let current = true;
    setAtItems([]);
    onCleanup(() => { current = false; });
    const reloadAttachments=()=>{attachmentLoad = loadAttachItems(slug).then(items => { if (current) setAtItems(items); }).catch(() => { if (current) setAtItems([]); });};
    const imported=(event:Event)=>{if((event as CustomEvent).detail?.slug===slug)reloadAttachments();};
    reloadAttachments();window.addEventListener('orb:context-imported',imported);onCleanup(()=>window.removeEventListener('orb:context-imported',imported));
  });
  /** What the current draft refers to, resolved against this project's files. */
  const mentioned = createMemo(() => mentionedChips(text(), atItems()));
  const mentionedIds = createMemo(() => new Set(mentioned().map(c => c.id)));
  createEffect(() => p.onAttachments?.(mentioned()));
  const [multiline, setMultiline] = createSignal(false);
  // Measuring scrollHeight forces a synchronous layout of the whole window on
  // every keystroke; with a long transcript that made typing lag per letter.
  // Single-line drafts are decided with canvas text metrics instead.
  let measureCtx: CanvasRenderingContext2D | null | undefined;
  let compactWidth = 0;
  const fitsOneLine = (value: string) => {
    if (!compactWidth) return false;
    measureCtx ??= document.createElement("canvas").getContext("2d");
    if (!measureCtx) return false;
    measureCtx.font = getComputedStyle(ta).font;
    return measureCtx.measureText(value).width < compactWidth - 24;
  };
  onMount(() => {
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => { if (!multiline()) compactWidth = entry.contentRect.width; });
    observer.observe(ta);
    onCleanup(() => observer.disconnect());
  });
  const resize = () => {
    const composer = ta.closest<HTMLElement>(".composer");
    if (!composer) return;
    // Canvas metrics decide most single-line drafts without touching layout.
    const value = text();
    if (!multiline() && !p.tall && !images().length && !value.includes("\n") && fitsOneLine(value)) {
      ta.style.height = "";
      return;
    }
    const val = ta.value;
    // Fast path for empty or short single-line compact inputs that cannot wrap:
    // skip collapsing and re-measuring the DOM box on every keystroke.
    const style = getComputedStyle(ta);
    const singleLineHeight = parseFloat(style.lineHeight) + parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    if (!multiline() && !val.includes("\n") && val.length <= 32 && ta.scrollHeight <= singleLineHeight + 1) {
      composer.classList.toggle("tall", Boolean(p.tall || images().length));
      ta.style.height = "";
      return;
    }
    // Measuring collapses the textarea: hold the composer's box so the
    // transcript above is not resized (and its scroll clamped), and keep the
    // caret line in view afterwards.
    const follow = document.activeElement === ta && ta.selectionEnd === val.length;
    const top = ta.scrollTop;
    composer.style.minHeight = `${composer.offsetHeight}px`;
    // Always decide from the compact width. Measuring the current layout makes
    // wrapped text alternate between narrow/compact and wide/tall on each key.
    composer.classList.remove("tall");
    ta.style.height = "0px";
    ta.style.minHeight = "0";
    const wrapped = val.includes("\n") || ta.scrollHeight > singleLineHeight + 1;
    setMultiline(wrapped);
    composer.classList.toggle("tall", Boolean(p.tall || images().length || wrapped));
    // Compact drafts return to their intrinsic single-line height, including
    // after a soft wrap; retaining a measured height leaves the controls below the text.
    ta.style.height = wrapped ? Math.min(ta.scrollHeight, 220) + "px" : "";
    ta.style.minHeight = "";
    composer.style.minHeight = "";
    ta.scrollTop = follow ? ta.scrollHeight : top;
  };

  createEffect(() => { const revision = p.revision; if (revision) { setMode(null); setText(current => { const next = revision.append && current ? `${current}\n\n${revision.text}` : revision.text; ta.value = next; return next; }); queueMicrotask(() => { resize(); ta?.focus(); }); } });
  const draftOf = (visible: string, m = mode()) => modePrompt(m, visible);
  // Report every change, including restored drafts and revisions, not only typing.
  createEffect(on([text, mode], ([visible, m]) => p.onDraft?.(draftOf(visible, m))));
  const write = (visible: string) => {
    ta.value = visible;
    setText(visible);
    resize();
  };
  const enterMode = (next: ComposerMode, visible: string) => {
    setMode(next);
    write(visible);
    ta.focus();
  };
  const clearMode = () => {
    setMode(null);
    ta.focus();
  };
  const pickSlash = (item: { id: ComposerMode }) => enterMode(item.id, "");
  /**
   * Write the chosen attachment into the sentence at the point `@` was typed.
   *
   * The mention is the reference: there is no separate list to keep in step, so
   * editing the text is editing the attachments, and the agent reads the same
   * words the user wrote.
   */
  const pickAttach = (item: AttachItem) => {
    const next = insertMention(text(), caret(), item);
    write(next.text);
    setAtOff(true);
    setCtx(false);
    setCtxFolder("");
    ta.focus();
    ta.setSelectionRange(next.caret, next.caret);
    setCaret(next.caret);
  };
  const send = async () => {
    // A direct upload stays attached even if its token was edited out of the draft.
    const missingTokens = p.directFileUpload ? uploaded.map(file => uploadToken(file.path)).filter(token => !text().includes(token)) : [];
    const original = missingTokens.length ? `${text().trimEnd()}${text().trim() ? "\n\n" : ""}${missingTokens.join(" ")}` : text();
    let payload = draftOf(original);
    if (!payload && !images().length && p.onEmptySubmit && !p.disabled && !sending()) { p.onEmptySubmit(); return; }
    if (p.disabled || (!payload && !images().length) || sendingLocked() || uploading() || readingImages()) return;
    if (folderBusy()) { setUploadError("Wait for the folder upload to finish, or cancel it. Your draft is kept."); return; }
    if (!p.textOnly && !p.imagesOnly && (mode() === "plan" || /^\/plan(?:\s|$)/.test(payload)) && !modes().some(m => m.id === "plan")) {
      setUploadError("Plan mode is not supported by this harness on this machine. Your draft is kept.");
      return;
    }
    const sideMode = !p.textOnly && !p.imagesOnly && (mode() === "btw" || /^\/btw(?:\s|$)/.test(payload));
    if (sideMode && !p.onBtw) { setUploadError("Side questions require an existing conversation."); return; }
    if (sideMode && !payload.replace(/^\/btw\s*/, "").trim() && !images().length && !uploaded.length) { setMode(null); p.onOpenBtw?.(); return; }
    const sentImages = images();
    const originalMode = mode();
    const originalUploads = uploaded;
    const draftScope = p.scope;
    const project = p.projectSlug;
    const destination = attachmentTarget();
    setPendingSend({text:original,images:sentImages});
    if(!sideMode)p.onPending?.({text:payload,images:sentImages,retry:()=>{uploaded=originalUploads;bumpUploads(n => n + 1);setText(original);setImages(sentImages);setMode(originalMode);void send();}});
    setSendingCount(c => c + 1);
    setText(""); setImages([]); ta.value=""; resize();
    let accepted = false;
    // What a failed send puts back; an unavailable attachment drops only its own mention.
    let restoreText = original, restoreUploads = originalUploads;
    try {
      await attachmentLoad;
      if (project !== p.projectSlug || draftScope !== p.scope || destination !== attachmentTarget()) return;
      const resolved = (p.textOnly || p.imagesOnly) ? {text: original, files: [], unavailable: []} : await prepareUploads(original, originalUploads, destination);
      if (project !== p.projectSlug || draftScope !== p.scope || destination !== attachmentTarget()) return;
      if (resolved.unavailable.length) {
        // Keep the draft and every other attachment; let the user re-attach or just send again.
        restoreText = resolved.text; restoreUploads = resolved.files;
        setStaleFiles(resolved.unavailable.map(file => file.folder ? `${file.source.name}/` : file.source.name));
        return;
      }
      uploaded = resolved.files; bumpUploads(n => n + 1);
      payload = draftOf(resolved.text);
      p.onAttachments?.(mentionedChips(resolved.text,[...atItems(), ...resolved.files.filter(file => file.destination.startsWith("context:")).map(file => ({id:`upload:${file.path}`,kind:"context" as const,label:file.source.name,path:file.path,project:file.destination.slice("context:".length),section:"Files" as const}))]));
      accepted = sideMode
        ? await p.onBtw!(payload.replace(/^\/btw\s*/, "").trim() || "Please look at the attachments.", sentImages, resolved.files)
        : await (p.sideQuestion ? p.onSend(payload || "Please look at the attached images.", sentImages, resolved.files) : p.onSend(payload || "Please look at the attached images.", sentImages)) !== false;
      if (accepted) {
        if (sideMode) p.onAttachments?.([]);
        if (uploaded === resolved.files) { uploaded = []; bumpUploads(n => n + 1); }
        setUploadError(null);
        if (draftTimer !== undefined) {
          clearTimeout(draftTimer);
          draftTimer = undefined;
        }
        pendingDraftSave = null;
        if (sendingCount() <= 1) setPendingSend(null);
        if (draftScope && !text() && !images().length) await saveComposerDraft(draftScope, {text:"",images:[]}).catch(swallow("composer.clearDraft", { scope: draftScope }));
        if (!text()) setMode(null);
      }
    } catch (error) { const message=error instanceof Error ? error.message : String(error); if (p.onSendError) p.onSendError(message); else setUploadError(message); }
    finally {
      setSendingCount(c => Math.max(0, c - 1));
      const keep = staleFiles().length > 0 && restoreText !== original;
      if (!accepted && (!p.retainFailedMessage || keep) && draftScope === p.scope && !text() && !images().length) {
        uploaded = restoreUploads; bumpUploads(n => n + 1);
        setMode(originalMode);setText(restoreText);setImages(sentImages);
        ta.value=restoreText;resize();
      }
      if (sendingCount() === 0) setPendingSend(null);
      if (!accepted && !sideMode) p.onPending?.(null);
      // The launch preview hides the composer. Restore visibility before focus.
      if (!accepted && draftScope === p.scope && ta.isConnected) ta.focus();
    }
  };
  const insertDictation = (t: string) => {
    const cur = ta.value;
    const { value, caret } = insertAtCaret(cur, ta.selectionStart ?? cur.length, ta.selectionEnd ?? cur.length, t);
    write(value);
    ta.setSelectionRange(caret, caret);
    ta.focus();
  };
  onMount(() => p.autofocus && ta.focus());
  const close = () => {
    setMenu(false);
    setCtx(false);
    setCtxFolder("");
    setWhich(null);
    if (slash()) setSlashOff(true);
    if (atQuery(text(), caret()).open) setAtOff(true);
  };
  const onEsc = (e: KeyboardEvent) => {
    if (e.defaultPrevented || e.isComposing || hasOverlay()) return;
    // Dismiss a pending mention query too: its file catalog can arrive
    // after Escape and must not reopen the picker over the next Enter.
    if (e.key === "Escape" && (menu() || ctx() || which() || slash() || atQuery(text(), caret()).open)) {
      e.stopPropagation();
      close();
      return;
    }
    if (e.key === "Escape" && p.editingQueued) {
      e.preventDefault();
      e.stopPropagation();
      p.editingQueued.onCancel();
    }
  };
  onMount(() => {
    window.addEventListener("keydown", onEsc, true);
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onEsc, true);
  });
  const plusItems = createMemo(() => {
    const raw: AttachItem[] = isConnected() ? atItems() : [];
    return browseAttachItems(raw, ctxFolder());
  });
  const plus = (
    <div class="plus-wrap" onPointerDown={(e) => e.stopPropagation()}>
      <input ref={fileInput} type="file" accept={p.imagesOnly ? "image/png,image/jpeg,image/webp,image/gif" : undefined} multiple hidden aria-label={p.imagesOnly || p.directFileUpload ? "Choose images" : "Choose files or images"} onChange={(event) => { const files = Array.from(event.currentTarget.files ?? []); event.currentTarget.value = ""; void attachMixed(files.map(file => ({ name: file.name, file }))); }} />
      <input ref={folderInput} type="file" multiple hidden aria-label="Choose a folder" {...{ webkitdirectory: "" }} onChange={(event) => { const files = Array.from(event.currentTarget.files ?? []); event.currentTarget.value = ""; void attachSources(files.map(file => ({ name: file.name, file, relativePath: file.webkitRelativePath || undefined }))); }} />
      <button class="plus" title={p.imagesOnly ? "Attach image" : p.directFileUpload ? "Attach file or image" : "Add context"} aria-label={p.imagesOnly ? "Attach image" : p.directFileUpload ? "Attach file or image" : undefined} disabled={uploading() || sendingLocked()} onClick={() => { if (p.imagesOnly || p.directFileUpload) void chooseFiles(); else { const next = !ctx(); setCtx(next); if (!next) setCtxFolder(""); } }}>
        <Ic.PlusIcon size={14} />
      </button>
      <Show when={ctx() && !p.imagesOnly && !p.directFileUpload}>
        <Menu label="Add context" class="plus-menu slash-menu" width={340} onClose={() => setCtx(false)}>
          <Show when={ctxFolder()} fallback={<><button class="menu-item" onClick={chooseFiles}><span class="menu-ico"><Ic.FileIcon size={14} /></span><span class="slash-item-label">Upload file or image…</span></button><button class="menu-item" onClick={chooseFolder}><span class="menu-ico"><Ic.FolderIcon size={14} /></span><span class="slash-item-label">Upload folder…</span></button></>}>
            <div class="slash-folder-bar">
              <button type="button" class="menu-item slash-back" onClick={() => { const cur = ctxFolder(); const slashIdx = cur.lastIndexOf("/"); setCtxFolder(slashIdx >= 0 ? cur.slice(0, slashIdx) : ""); }}>
                <span class="menu-ico"><Ic.ArrowLeft size={14} /></span>
                <span class="slash-item-label">{ctxFolder()}/</span>
              </button>
              <button type="button" class="slash-attach-folder" title={`Attach @${ctxFolder()}/`} onClick={() => {
                const f = ctxFolder();
                const existing = atItems().find((it) => it.section === "Folders" && (it.path ?? "").replace(/\/$/, "").toLowerCase() === f.toLowerCase());
                pickAttach(existing ?? { id: `folder:${f}`, kind: "folder", section: "Folders", path: f, label: `${f}/` });
              }}>Attach</button>
            </div>
          </Show>
          <Show when={plusItems().some((i) => i.section === "Folders")}>
            <div class="slash-head">Folders</div>
            <For each={plusItems().filter((i) => i.section === "Folders")}>
              {(it) => {
                const display = () => ctxFolder() && it.label.toLowerCase().startsWith(`${ctxFolder().toLowerCase()}/`) ? it.label.slice(ctxFolder().length + 1) : it.label;
                return (
                  <button class={`menu-item ${mentionedIds().has(it.id) ? "on" : ""}`} title={it.path ?? it.label} onClick={() => setCtxFolder((it.path ?? it.label).replace(/\/$/, ""))}>
                    <span class="menu-ico"><Ic.FolderIcon size={14} /></span>
                    <span class="slash-item-label">{display()}</span>
                    <span class="menu-attachment-mark" aria-hidden="true">{mentionedIds().has(it.id) ? "✓" : ""}</span>
                    <span class="slash-chevron"><Ic.ChevronRight size={12} /></span>
                  </button>
                );
              }}
            </For>
          </Show>
          <Show when={plusItems().some((i) => i.section === "Files")}>
            <div class="slash-head">Files</div>
            <For each={plusItems().filter((i) => i.section === "Files")}>
              {(item) => {
                const display = () => ctxFolder() && item.label.toLowerCase().startsWith(`${ctxFolder().toLowerCase()}/`) ? item.label.slice(ctxFolder().length + 1) : item.label;
                return (
                  <button
                    class={`menu-item ${mentionedIds().has(item.id) ? "on" : ""}`}
                    title={item.path ?? item.label}
                    onClick={() => { if (p.onAttachments) pickAttach(item); }}
                  >
                    <span class="menu-ico"><Ic.FileIcon size={14} /></span>
                    <span class="slash-item-label">{display()}</span>
                    <span class="menu-attachment-mark" aria-hidden="true">{mentionedIds().has(item.id) ? "✓" : ""}</span>
                  </button>
                );
              }}
            </For>
          </Show>
        </Menu>
      </Show>
    </div>
  );
  // Two pickers, Cursor-style: harness first (Claude Code, Codex, …), then
  // the model that harness can run. Changing the harness resets the model.
  const choice = () => harnessChoices(p.uploadTarget).find((c) => c.backend.id === pick()?.backend);
  const modelLabel = () => {
    const m = choice()?.models.find((x) => x.value === pick()?.model);
    return m ? shortModelLabel(m.label) : (pick()?.model ?? "Model");
  };
  const modelBtn = (
    <Show when={p.picker !== false}>
      <div class="picks" onPointerDown={(e) => e.stopPropagation()}>
        <Show
          when={live()}
          fallback={
            <div class="model-wrap">
              <button class="model" onClick={() => setMenu(!menu())}>
                {model()} <Ic.ChevronDown size={12} />
              </button>
              <Show when={menu()}>
                <Picker label="Models" searchable={false} selected={model()} items={MODELS.map(m => ({id:m,label:m}))}
                  onClose={() => setMenu(false)} onSelect={m => {setModel(m);setMenu(false);}}/>
              </Show>
            </div>
          }
        >
          <div class="model-wrap">
            <button class={`model ${which() === "harness" ? "on" : ""}`} title="Harness" onClick={() => {
              const opening = which() !== "harness";
              setWhich(opening ? "harness" : null);
              // Discover newly installed CLIs without recreating the composer.
              if (opening && p.harnessIds) void refreshLocalAgents(false);
              if (opening && isConnected()) void refreshHarnessChoices();
              if (opening && p.uploadTarget !== "local" && p.uploadTarget !== "side") void refreshNodeAntigravityModels(p.uploadTarget ?? "core");
            }}>
              {choice()?.backend.name ?? "Harness"} <Ic.ChevronDown size={12} />
            </button>
            <Show when={which() === "harness"}>
              <Picker label="Harness" searchable={false} selected={pick()?.backend}
                items={harnessChoices(p.uploadTarget).filter(c => !p.harnessIds || p.harnessIds.includes(c.backend.id)).map(c => ({id:c.backend.id,label:c.backend.name,description:p.remoteSupport?.(c.backend.id).note || `${c.models.length} model${c.models.length === 1 ? "" : "s"}`}))}
                onClose={() => setWhich(null)} onSelect={id => {
                  const c = harnessChoices(p.uploadTarget).find(c => c.backend.id === id);
                  if (c && id !== pick()?.backend) {
                    const effort = normalizeEffort(pick()?.effort, id);
                    setHarnessPick({backend:id,model:c.models[0].value,...(effort ? {effort} : {})});
                  }
                  setWhich(null);
                }}/>

            </Show>
          </div>
          <span class="picks-sep">·</span>
          <div class="model-wrap">
            <button class={`model ${which() === "model" ? "on" : ""}`} title="Model" onClick={() => setWhich(which() === "model" ? null : "model")}>
              {modelLabel()} <Ic.ChevronDown size={12} />
            </button>
            <Show when={which() === "model"}>
              <Picker label="Models" searchLabel="Search models" selected={pick()?.model}
                items={(choice()?.models ?? []).map(m => ({id:m.value,label:shortModelLabel(m.label)}))}
                onClose={() => setWhich(null)} onSelect={value => {
                  const backend = choice()!.backend.id;
                  const effort = normalizeEffort(pick()?.effort, backend);
                  setHarnessPick({...pick()!,backend,model:value,...(effort ? {effort} : {})});setWhich(null);
                }}/>

            </Show>
          </div>
          {/* Effort, after harness and model. Only rendered for a harness the
              core actually accepts an effort for — everything else has
              model_effort forced to null server-side. */}
          <Show when={harnessSupportsEffort(pick()?.backend)}>
            <span class="picks-sep">·</span>
            <div class="model-wrap">
              <button
                class={`model ${which() === "effort" ? "on" : ""}`}
                title="Reasoning effort"
                aria-label={`Reasoning effort: ${effortLabel(pick()?.effort,pick()?.backend,pick()?.model)}`}
                onClick={() => setWhich(which() === "effort" ? null : "effort")}
              >
                {effortLabel(pick()?.effort,pick()?.backend,pick()?.model)} <Ic.ChevronDown size={12} />
              </button>
              <Show when={which() === "effort"}>
                <Picker label="Reasoning effort" searchable={false} selected={pick()?.effort ?? ""}
                  items={[{id:"",label:defaultEffortLabel(pick()?.backend,pick()?.model)},...supportedEfforts(pick()?.backend).map(e => ({id:e,label:effortLabel(e)}))]}
                  onClose={() => setWhich(null)} onSelect={value => {
                    const cur = pick()!; const effort = normalizeEffort(value, cur.backend);
                    setHarnessPick({...cur,backend:cur.backend,model:cur.model,...(effort ? {effort} : {})});setWhich(null);
                  }}/>

              </Show>
            </div>
          </Show>
          <Show when={pick()?.backend === "codex"}>
            <span class="picks-sep">·</span><CodexSpeedPicker model={pick()?.model??""} value={pick()?.service_tier??"standard"} local={p.uploadTarget==="local"} onChange={tier=>setHarnessPick({...pick()!,service_tier:tier})}/>
            <span class="picks-sep">·</span><CyberPicker value={draftCyber()} model={pick()?.model??""} remote={!!p.uploadTarget&&p.uploadTarget!=="core"&&p.uploadTarget!=="local"} onChange={setDraftCyber}/>
          </Show>
        </Show>
      </div>
    </Show>
  );
  // Cursor keeps the microphone mounted while a turn is streaming; Stop sits
  // beside it. A draft still sends — the backend queues it for the next turn.
  const sendBtn = (
    <div class="send-slot">
      <Show when={(text().trim() || images().length) && !slash() && !voiceActive()}>
        <button class="send" disabled={p.disabled || uploading() || sendingLocked() || readingImages()} onClick={send} aria-label={p.sendLabel} title={mode()==="btw" ? "Ask side question" : p.busy ? "Queue for next turn" : p.sendLabel ?? "Send"}>
          <Ic.ArrowUpIcon size={14} />
        </button>
      </Show>
      <Show when={p.busy && p.onStop}>
        <button class="send stop" disabled={p.disabled} onClick={p.onStop} title="Stop">
          <Ic.StopIcon size={14} />
        </button>
      </Show>
    </div>
  );
  const voice = (
    <Show when={voiceAvailable()}>
      <div class="voice-slot" onPointerDown={(e) => e.stopPropagation()}>
        <VoiceButton scope={p.scope} onText={insertDictation} onActive={setVoiceActive} />
      </div>
    </Show>
  );
  const atMenu=<Show when={at()}>{s=><MentionPicker anchor={ta} onClose={() => setAtOff(true)} items={s().items} index={atHi()} highlight={setAtHi} pick={pickAttach} folder={s().folder || undefined} onBack={()=>{const cur=s().folder;const idx=cur.lastIndexOf("/");setAtFolder(idx>=0?cur.slice(0,idx):"");}} onOpenFolder={setAtFolder}/>}</Show>;
  const slashMenu = (
    <Show when={slash()}>
      {(s) => (
        <Popover role="listbox" label="Commands" class="slash-menu" anchor={ta} placement="top-start" width={340} trap={false} onClose={() => setSlashOff(true)}>
          <div class="slash-head">Modes</div>
          <For each={s().items}>
            {(it, i) => (
              <button
                type="button"
                role="option"
                aria-selected={slashHi() === i()}
                class={`menu-item ${slashHi() === i() ? "on" : ""}`}
                title={it.title}
                onMouseEnter={() => setSlashHi(i())}
                onClick={() => pickSlash(it)}
              >
                <span class="menu-ico"><Ic.TargetIcon size={14} /></span>
                {it.label}
              </button>
            )}
          </For>
        </Popover>
      )}
    </Show>
  );
  return (<>
    <Show when={!p.onPending && pendingSend()}>{pending=><OptimisticMessage draft={pending()} />}</Show>
    <div ref={composerElement} class={`composer ${p.tall || images().length || multiline() ? "tall" : ""} ${voiceActive() ? "voice-on" : ""} ${mode() || p.editingQueued ? "has-mode" : ""}`} data-mode={mode() ?? ""}
      onDragOver={e=>{if(Array.from(e.dataTransfer?.types??[]).includes("Files")){e.preventDefault();e.stopPropagation();if(e.dataTransfer)e.dataTransfer.dropEffect="copy";e.currentTarget.classList.add("drop-active");}}}
      onDragLeave={e=>{if(!e.currentTarget.contains(e.relatedTarget as Node))e.currentTarget.classList.remove("drop-active");}}
      onDrop={e=>{e.preventDefault();e.stopPropagation();e.currentTarget.classList.remove("drop-active");if(sendingLocked()||uploading()||readingImages())return;const data=e.dataTransfer;if(!data)return;void sourcesFromDataTransfer(data).then(sources=>sources.some(source=>source.relativePath)?attachSources(sources):attachMixed(sources)).catch(error=>setUploadError(error instanceof Error?error.message:String(error)));}}
      onClick={() => !voiceActive() && ta.focus()}>
      <Show when={!p.textOnly} fallback={<Show when={p.attachDisabledReason}>{reason => <div class="plus-wrap" title={reason()}><button class="plus" type="button" disabled aria-label="Attach file or image" aria-description={reason()} title={reason()}><Ic.PlusIcon size={14} /></button></div>}</Show>}>{plus}</Show>
      {slashMenu}
      {atMenu}
      <Show when={uploading()}><div class="composer-upload-status" role="status">Attaching file…</div></Show>
      <Show when={pendingLargeUploads().length > 0}>
        <div class="composer-large-confirm" role="alertdialog" aria-label="Confirm large file upload" onClick={(e) => e.stopPropagation()}>
          <div class="composer-large-confirm-text">
            <strong>Large file{pendingLargeUploads().length > 1 ? "s" : ""}</strong>
            <span>
              {pendingLargeUploads().map((item) => `${item.source.name} (${formatFileSize(item.size)})`).join(", ")} exceed{pendingLargeUploads().length === 1 ? "s" : ""} the standard limit ({formatFileSize(softLimitForDestination(attachmentTarget()))}). Upload in the background with resumable chunks?
            </span>
          </div>
          <div class="composer-large-confirm-actions">
            <button type="button" class="s-btn" onClick={() => setPendingLargeUploads([])}>Cancel</button>
            <button type="button" class="s-btn primary" onClick={confirmLargeUploads}>Upload in background</button>
          </div>
        </div>
      </Show>
      <Show when={scopedBgUploads().length > 0}>
        <div class="composer-bg-uploads" role="status" aria-live="polite" onClick={(e) => e.stopPropagation()}>
          <For each={scopedBgUploads()}>{(item) => {
            const pct = () => item.totalBytes > 0 ? Math.min(100, Math.round((item.uploadedBytes / item.totalBytes) * 100)) : 0;
            return (
              <div class={`composer-bg-upload-row ${item.state === "failed" ? "error" : item.state}`}>
                <span class="composer-bg-upload-name" title={item.name}>{item.name}</span>
                <span class="composer-bg-upload-meta">
                  {item.state === "paused"
                    ? `Paused · ${pct()}%`
                    : item.state === "failed"
                      ? `Interrupted (${pct()}%)${item.error ? ` — ${item.error}` : ""}`
                      : `${pct()}% · ${formatFileSize(item.uploadedBytes)} / ${formatFileSize(item.totalBytes)}${item.speedBps > 0 ? ` · ${formatFileSize(item.speedBps)}/s` : ""}`}
                </span>
                <div class="composer-bg-upload-actions">
                  <Show when={item.state === "uploading"}>
                    <button type="button" class="bg-upload-btn" onClick={() => pauseBackgroundUpload(item.id)}>Pause</button>
                  </Show>
                  <Show when={item.state === "paused" || item.state === "failed"}>
                    <button type="button" class="bg-upload-btn" onClick={() => resumeBackgroundUpload(item.id)}>Resume</button>
                  </Show>
                  <button type="button" class="bg-upload-btn" aria-label={`Cancel upload of ${item.name}`} onClick={() => cancelBackgroundUpload(item.id)}>×</button>
                </div>
                <span class="bg-upload-bar"><i style={{ width: `${pct()}%` }} /></span>
              </div>
            );
          }}</For>
        </div>
      </Show>
      <Show when={pendingFolder()}>{request => (
        <div class="composer-large-confirm" role="alertdialog" aria-label="Confirm folder upload" onClick={(e) => e.stopPropagation()}>
          <div class="composer-large-confirm-text">
            <strong>Large folder</strong>
            <span>{request().root}/ has {request().files.length} files ({formatFileSize(request().files.reduce((sum, file) => sum + file.size, 0))}). Upload all of them?</span>
          </div>
          <div class="composer-large-confirm-actions">
            <button type="button" class="s-btn" onClick={() => setPendingFolder(null)}>Cancel</button>
            <button type="button" class="s-btn primary" onClick={() => { const next = request(); setPendingFolder(null); void startFolder(next); }}>Upload folder</button>
          </div>
        </div>
      )}</Show>
      <Show when={folderUploads().length || fileChips().some(file => file.folder)}>
        <div class="composer-bg-uploads" aria-label="Attached folders">
          <For each={folderUploads()}>{upload => <FolderUploadChip batch={upload.batch}
            onCancel={() => { upload.cancel(); dropFolder(upload); }}
            onRetry={() => void runFolder(upload)}
            onSkipFailed={() => finishFolder(upload)} />}</For>
          <For each={fileChips().filter(file => file.folder)}>{file => <FolderUploadChip folder={file.folder} onRemove={() => removeUploadedFile(file)} />}</For>
        </div>
      </Show>
      <Show when={staleFiles().length}>
        <div class="composer-stale-attachments" role="status" onClick={(e) => e.stopPropagation()}>
          <span>File no longer available — re-attach: {staleFiles().join(", ")}. Removed from the message; your text is kept.</span>
          <Show when={!p.textOnly && !p.imagesOnly}><button type="button" class="bg-upload-btn" onClick={() => { setStaleFiles([]); void chooseFiles(); }}>Re-attach</button></Show>
          <button type="button" class="bg-upload-btn" aria-label="Dismiss" onClick={() => setStaleFiles([])}>×</button>
        </div>
      </Show>
      <ErrorToast error={uploadError()} title="Couldn’t upload the file" onDismiss={() => setUploadError(null)} />
      <Show when={mode()}>{m => <ModeChip mode={m()} onClear={clearMode} />}</Show>
      <Show when={!mode() && p.editingQueued}>{editing => <span class="mode-chip edit-queued" role="status" aria-label="Editing a queued message">
        <Ic.PencilIcon size={12} /><span class="mode-chip-label">Edit Queued</span>
        <button type="button" class="mode-chip-x" tabIndex={-1} title="Stop editing" aria-label="Stop editing the queued message" onClick={e => { e.preventDefault(); e.stopPropagation(); editing().onCancel(); }}><Ic.CloseIcon size={10} /></button>
      </span>}</Show>
      <div class="composer-field">
        <Show when={images().length}><div class="composer-images"><For each={images()}>{image => <div class="composer-image"><img src={image.dataUrl} alt={image.reference ? `Image #${image.reference}` : "Attached image"} title="Open preview" onClick={e => { e.stopPropagation(); setViewing(images().indexOf(image)); }} /><Show when={image.reference}><span class="composer-image-reference">#{image.reference}</span></Show><button class="icon-btn" aria-label="Remove image" title="Remove image" onClick={e => { e.stopPropagation(); setImages(current => current.filter(item => item.id !== image.id)); if (image.reference) { const value = text().replaceAll(`[Image #${image.reference}]`, ""); setText(value); ta.value = value; resize(); } }}><Ic.CloseIcon size={12}/></button></div>}</For></div></Show><Show when={viewing() !== null && images().length}><Lightbox items={draftLightbox(images())} index={viewing()!} onClose={() => setViewing(null)} /></Show>
        <Show when={p.directFileUpload && fileChips().length}><div class="attach-pills" aria-label="Attached files"><For each={fileChips()}>{file => <button type="button" class="pill on" title={`Remove ${file.source.name}`} aria-label={`Remove ${file.source.name}`} onClick={e => { e.stopPropagation(); removeUploadedFile(file); }}><Ic.FileIcon size={12}/> {file.source.name} <Ic.CloseIcon size={12}/></button>}</For></div></Show>
        <ErrorToast error={imageError()} title="Couldn’t add the image" onDismiss={() => setImageError(null)} />
        <textarea readOnly={sendingLocked()}
          ref={ta}
          aria-label={p.inputLabel}
          onPaste={event => {
            const others = Array.from(event.clipboardData?.files ?? []).filter(file => !file.type.startsWith("image/"));
            if (others.length && !p.textOnly && !p.imagesOnly) { event.preventDefault(); void attachMixed(Array.from(event.clipboardData!.files).map(file => ({ name: file.name, file }))); return; }
            void pasteImages(event);
          }}
          rows={1}
          // Keep the placeholder clear of the native caret without shifting typed text.
          placeholder={"\u2009" + (mode() === "btw" ? "Ask without interrupting…" : mode() === "goal" ? "Describe the objective" : mode() === "plan" ? "Plan before making changes…" : p.placeholder)}
          onInput={(e) => {
            const next = e.currentTarget.value;
            setSlashOff(false);
            setAtOff(false);
            setCaret(e.currentTarget.selectionStart ?? next.length);
            if (!mode() && /^\/btw(?:\s|$)/.test(next) && p.onBtw) { enterMode('btw', next.replace(/^\/btw\s*/,'')); return; }
            if (!mode() && /^\/plan(?:\s|$)/.test(next) && modes().some(m=>m.id==='plan')) {
              enterMode('plan', next.replace(/^\/plan\s*/,'')); return;
            }
            if (!mode() || mode() === "goal") {
              const absorbed = absorbGoalPrefix(next);
              if (absorbed !== null && modes().some((it) => it.id === "goal")) {
                enterMode("goal", absorbed);
                return;
              }
            }
            write(next);
          }}
          onClick={() => setCaret(ta.selectionStart ?? text().length)}
          onKeyUp={() => setCaret(ta.selectionStart ?? text().length)}
          onKeyDown={(e) => {
            const atItemsOpen = at()?.items;
            if (atItemsOpen && atItemsOpen.length) {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                const n = atItemsOpen.length;
                setAtHi((i) => (e.key === "ArrowDown" ? (i + 1) % n : (i - 1 + n) % n));
                return;
              }
              if ((e.key === "Enter" || e.key === "Tab") && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                pickAttach(atItemsOpen[Math.min(atHi(), atItemsOpen.length - 1)]);
                return;
              }
            }
            const items = slash()?.items;
            if (items) {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                const n = items.length;
                setSlashHi((i) => (e.key === "ArrowDown" ? (i + 1) % n : (i - 1 + n) % n));
                return;
              }
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                pickSlash(items[Math.min(slashHi(), items.length - 1)]);
                return;
              }
              if (e.key === "Tab") {
                e.preventDefault();
                pickSlash(items[Math.min(slashHi(), items.length - 1)]);
                return;
              }
            }
            if (e.key === "Backspace" && mode() && !text() && ta.selectionStart === 0 && ta.selectionEnd === 0) {
              e.preventDefault();
              clearMode();
              return;
            }
            if (e.key === "ArrowRight" && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && !e.isComposing && !text() && !images().length && !mode() && !p.editingQueued && p.onEditFirstQueued) {
              e.preventDefault();
              p.onEditFirstQueued();
              return;
            }
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault();
              send();
            }
          }}
        />
      </div>
      {p.controls ?? modelBtn}
      {voice}
      {sendBtn}
    </div>
  </>);
}

// Keep the last message reachable while the transparent dock floats over the transcript.
export function floatingDock(el: HTMLDivElement) {
  let parent: HTMLElement | null = null;
  const update = () => {
    const bounds = el.getBoundingClientRect();
    parent?.style.setProperty("--dock-height", `${bounds.height}px`);
    const composer = el.querySelector<HTMLElement>(".composer");
    if (composer) el.closest<HTMLElement>(".app")?.style.setProperty(
      "--composer-bottom-space", `${bounds.bottom - composer.getBoundingClientRect().bottom}px`,
    );
  };
  const observer = new ResizeObserver(update);
  queueMicrotask(() => { parent = el.parentElement; update(); observer.observe(el); });
  onCleanup(() => { observer.disconnect(); parent?.style.removeProperty("--dock-height"); el.closest<HTMLElement>(".app")?.style.removeProperty("--composer-bottom-space"); });
}

