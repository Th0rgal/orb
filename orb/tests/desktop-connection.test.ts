import {afterEach,it,expect,vi} from 'vitest';
afterEach(()=>{delete (window as any).__TAURI__;localStorage.clear();vi.resetModules();});
it('restores the same desktop connection into an empty dev origin',async()=>{
 localStorage.clear();const invoke=vi.fn(async(command:string)=>command==='desktop_connection_load'?{api_url:'https://core.example',token:'fixture-token'}:undefined);
 (window as any).__TAURI__={core:{invoke}};
 const api=await import('../src/api');await api.restoreDesktopConnection();
 expect(api.getApiUrl()).toBe('https://core.example');expect(api.getJwt()).toBe('fixture-token');expect(api.isConnected()).toBe(true);
 api.clearConnection();await vi.waitFor(()=>expect(invoke).toHaveBeenCalledWith('desktop_connection_save',{connection:null}));
});
it('preserves an explicit existing login rather than switching accounts on startup',async()=>{
 localStorage.setItem('orb.jwt','existing');localStorage.setItem('orb.apiUrl','https://other.example');
 const invoke=vi.fn(async()=>undefined);(window as any).__TAURI__={core:{invoke}};
 const api=await import('../src/api');await api.restoreDesktopConnection();
 expect(invoke).not.toHaveBeenCalledWith('desktop_connection_load');
 await vi.waitFor(()=>expect(invoke).toHaveBeenCalledWith('desktop_connection_save',{connection:{api_url:'https://other.example',token:'existing'}}));
});
