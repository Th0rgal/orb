import {beforeEach,it,expect,vi} from 'vitest';
const mocks=vi.hoisted(()=>({version:1,api:vi.fn(),manifest:vi.fn(),encoded:vi.fn()}));
vi.mock('../src/api',()=>({connectionVersion:()=>mocks.version,api:mocks.api}));
vi.mock('../src/projectContext',()=>({contextManifest:mocks.manifest}));
vi.mock('../src/uploads',()=>({encoded:mocks.encoded}));
import {importProjectFiles,CONTEXT_FILE_LIMIT,CONTEXT_PROJECT_LIMIT} from '../src/projectFileImport';
beforeEach(()=>{mocks.version=1;mocks.api.mockReset().mockImplementation(async(path:string)=>path.endsWith('/blobs')?{hash:'abc'}:{conflict:false});mocks.manifest.mockReset().mockResolvedValue({revision:1,entries:{}});mocks.encoded.mockReset().mockResolvedValue(btoa('%PDF-1.7\x00\xff'));});
it('imports unchanged binary bytes into the selected subfolder and publishes its path',async()=>{
 const event=vi.fn();window.addEventListener('orb:context-imported',event);
 const result=await importProjectFiles('health','PPL',[{name:'guide.pdf',localPath:'/tmp/guide.pdf'}]);
 expect(result).toEqual({paths:['PPL/guide.pdf'],warnings:[]});
 expect([...mocks.api.mock.calls[0][1].body]).toEqual([...new TextEncoder().encode('%PDF-1.7'),0,255]);
 expect(JSON.parse(mocks.api.mock.calls[1][1].body)).toMatchObject({path:'PPL/guide.pdf',base:null,hash:'abc'});
 expect(mocks.encoded).toHaveBeenCalledWith(expect.anything(),CONTEXT_FILE_LIMIT);
 expect(event).toHaveBeenCalledTimes(1);window.removeEventListener('orb:context-imported',event);
});
it('warns before reading an oversized browser file and does not publish it',async()=>{
 const result=await importProjectFiles('health','PPL',[{name:'large.pdf',file:{size:CONTEXT_FILE_LIMIT+1} as File}]);
 expect(result.paths).toEqual([]);expect(result.warnings[0]).toContain('10 MiB');expect(mocks.encoded).not.toHaveBeenCalled();expect(mocks.api).not.toHaveBeenCalled();
});
it('preserves an existing filename and refuses exceeding the project quota',async()=>{
 mocks.manifest.mockResolvedValueOnce({entries:{'PPL/guide.pdf':{size:5}}});
 expect((await importProjectFiles('health','PPL',[{name:'guide.pdf'}])).paths).toEqual(['PPL/guide (2).pdf']);
 mocks.api.mockClear();mocks.manifest.mockResolvedValueOnce({entries:{existing:{size:CONTEXT_PROJECT_LIMIT}}});
 const result=await importProjectFiles('health','PPL',[{name:'guide.pdf'}]);expect(result.warnings[0]).toContain('100 MiB');expect(mocks.api).not.toHaveBeenCalled();
});
it('does not publish to a new connection after reading the file',async()=>{
 mocks.encoded.mockImplementationOnce(async()=>{mocks.version++;return btoa('PDF');});
 await expect(importProjectFiles('health','PPL',[{name:'guide.pdf'}])).rejects.toThrow('Connection changed');expect(mocks.api).not.toHaveBeenCalled();
});
it('keeps a conditional-write conflict visible instead of claiming a successful import',async()=>{
 mocks.api.mockResolvedValueOnce({hash:'abc'}).mockResolvedValueOnce({conflict:true});
 const result=await importProjectFiles('health','PPL',[{name:'guide.pdf'}]);expect(result.paths).toEqual([]);expect(result.warnings[0]).toContain('existing file was preserved');
});
