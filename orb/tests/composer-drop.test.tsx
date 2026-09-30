import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { Composer } from '../src/App';
import {nativeComposerDrop} from '../src/composerDrop';
const handlers = new Map<string, (event: any) => void>();
afterEach(() => { cleanup(); handlers.clear(); delete (window as any).__TAURI__; vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it('inserts all native local paths while the agent runs and deduplicates the relay', async () => {
  const invoke = vi.fn(), send = vi.fn();
  (window as any).__TAURI__ = { core: { invoke }, event: { listen: vi.fn(async (name, handler) => { handlers.set(name, handler); return () => handlers.delete(name); }) } };
  vi.stubGlobal('devicePixelRatio', 2);
  const view = render(() => <Composer placeholder="Drop here" uploadTarget="local" busy={true} onSend={send} onStop={() => {}} />);
  const composer = view.container.querySelector('.composer') as HTMLElement;
  vi.spyOn(composer, 'getClientRects').mockReturnValue([{}] as unknown as DOMRectList);
  vi.spyOn(composer, 'getBoundingClientRect').mockReturnValue({ left: 10, right: 310, top: 100, bottom: 200 } as DOMRect);
  const input = screen.getByPlaceholderText('Drop here') as HTMLTextAreaElement;
  fireEvent.input(input, { target: { value: 'Inspect: ' } });
  input.setSelectionRange(9, 9);
  const paths = ['/Users/test/Downloads/import.jsonl', '/Users/test/Downloads/import.json', '/Users/test/Downloads/import.txt'];
  await waitFor(() => expect(handlers.has('tauri://drag-drop')).toBe(true));
  expect((window as any).__TAURI__.event.listen).toHaveBeenCalledWith('tauri://drag-drop', expect.any(Function), { target: { kind: 'Webview', label: 'main' } });
  handlers.get('tauri://drag-drop')!({ payload: { paths, position: { x: 100, y: 300 } } });
  handlers.get('orb-upload-drop')!({ payload: { paths, x: 100, y: 300 } });
  await waitFor(() => expect(input.value).toBe('Inspect: ' + paths.map(path => '@' + path + ' ').join('')));
  expect(invoke.mock.calls.map(call => call[0])).not.toContain('read_upload_file');
  expect(invoke.mock.calls.map(call => call[0])).not.toContain('stage_upload_file');
  expect(send).not.toHaveBeenCalled();
  handlers.get('tauri://drag-drop')!({ payload: { paths: ['/outside.txt'], position: { x: 100, y: 50 } } });
  expect(input.value).not.toContain('outside');
  cleanup();
  await waitFor(() => expect(handlers.has('tauri://drag-drop')).toBe(false));
  expect(handlers.has('orb-upload-drop')).toBe(false);
});

it('uploads Finder files to shared project context before sending context references', async () => {
  vi.spyOn(navigator,'platform','get').mockReturnValue('MacIntel');
  vi.stubGlobal('devicePixelRatio',2);
  const invoke = vi.fn(async () => btoa('DROP_TEST_CONTENT'));
  (window as any).__TAURI__ = { core: { invoke }, event: { listen: vi.fn(async (name, handler) => { handlers.set(name, handler); return () => handlers.delete(name); }) } };
  const requests: {url:string; init:any}[] = [];
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    requests.push({url:String(url),init});
    if (String(url).endsWith('/blobs')) return new Response(JSON.stringify({hash:'abc'}));
    if (String(url).endsWith('/operations')) return new Response(JSON.stringify({conflict:false}));
    return new Response(JSON.stringify([]));
  }));
  const send = vi.fn(), attachments = vi.fn();
  const view = render(() => <Composer placeholder="Remote drop" projectSlug="drop-test" uploadTarget="ashur" busy={false} onSend={send} onStop={()=>{}} onAttachments={attachments} />);
  const el = view.container.querySelector('.composer') as HTMLElement;
  vi.spyOn(el,'getClientRects').mockReturnValue([{}] as unknown as DOMRectList);
  vi.spyOn(el,'getBoundingClientRect').mockReturnValue({left:60,right:400,top:60,bottom:400} as DOMRect);
  await waitFor(()=>expect(handlers.has('orb-upload-drop')).toBe(true));
  handlers.get('orb-upload-drop')!({payload:{paths:['/Users/test/a file.txt','/Users/test/image.png'],x:100,y:100}});
  const input=screen.getByPlaceholderText('Remote drop') as HTMLTextAreaElement;
  await waitFor(()=>expect(input.value).toContain('image.png'));
  expect(input.value).toContain('@"attachments/');
  expect(input.value).not.toContain('/Users/');
  expect(requests.filter(r=>r.url.endsWith('/blobs'))).toHaveLength(2);
  expect(requests.some(r=>r.url.endsWith('/api/uploads'))).toBe(false);
  expect(invoke.mock.calls.every(call=>call[0]==='read_upload_file')).toBe(true);
  fireEvent.click(screen.getByTitle('Send'));
  await waitFor(()=>expect(send).toHaveBeenCalledOnce());
  expect(attachments).toHaveBeenLastCalledWith(expect.arrayContaining([expect.objectContaining({kind:'context',project:'drop-test',path:expect.stringMatching(/^attachments\//)})]));
});

it('keeps typed text and reports a failed shared-context upload without sending', async () => {
  (window as any).__TAURI__ = {core:{invoke:vi.fn(async()=>btoa('data'))},event:{listen:vi.fn(async(name,handler)=>{handlers.set(name,handler);return ()=>handlers.delete(name);})}};
  vi.stubGlobal('fetch',vi.fn(async(url)=>String(url).endsWith('/blobs')?new Response('Upload unavailable',{status:503}):new Response('[]')));
  const send=vi.fn();
  const view=render(()=><Composer placeholder="Failure drop" projectSlug="test" uploadTarget="core" busy={false} onSend={send} onStop={()=>{}}/>);
  const el=view.container.querySelector('.composer') as HTMLElement;
  vi.spyOn(el,'getClientRects').mockReturnValue([{}] as unknown as DOMRectList);
  vi.spyOn(el,'getBoundingClientRect').mockReturnValue({left:0,right:400,top:0,bottom:400} as DOMRect);
  const input=screen.getByPlaceholderText('Failure drop') as HTMLTextAreaElement;
  fireEvent.input(input,{target:{value:'Keep this draft'}});
  await waitFor(()=>expect(handlers.has('orb-upload-drop')).toBe(true));
  handlers.get('orb-upload-drop')!({payload:{paths:['/test/file.txt'],x:100,y:100}});
  await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('Upload unavailable'));
  expect(input.value).toBe('Keep this draft');expect(send).not.toHaveBeenCalled();
});

it('routes a Retina Finder drop to the selected nested folder only once',async()=>{
 vi.spyOn(navigator,'platform','get').mockReturnValue('MacIntel');vi.stubGlobal('devicePixelRatio',2);
 (window as any).__TAURI__={event:{listen:vi.fn(async(name,handler)=>{handlers.set(name,handler);return ()=>handlers.delete(name);})}};
 const attach=vi.fn(async()=>{}),target=document.createElement('div');target.dataset.dropFolder='PPL';
 vi.spyOn(target,'getClientRects').mockReturnValue([{}] as unknown as DOMRectList);
 vi.spyOn(target,'getBoundingClientRect').mockReturnValue({left:20,right:300,top:100,bottom:150} as DOMRect);
 const find=vi.fn((x:number,y:number)=>x===80&&y===120?target:undefined);
 function Tree(){let root!:HTMLDivElement;nativeComposerDrop(()=>root,attach,find);return <div ref={root}/>;}
 render(()=><Tree/>);await waitFor(()=>expect(handlers.has('tauri://drag-drop')).toBe(true));
 handlers.get('tauri://drag-drop')!({payload:{paths:['/Downloads/guide.pdf'],position:{x:80,y:120}}});
 handlers.get('orb-upload-drop')!({payload:{paths:['/Downloads/guide.pdf'],x:80,y:120}});
 expect(attach).toHaveBeenCalledExactlyOnceWith([{name:'guide.pdf',localPath:'/Downloads/guide.pdf'}],target);
 handlers.get('orb-upload-drop')!({payload:{paths:['/Downloads/guide.pdf'],x:500,y:120}});
 expect(attach).toHaveBeenCalledTimes(1);
});
