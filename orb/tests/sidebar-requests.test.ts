import {afterEach, expect, it, vi} from 'vitest';
import {createSidebarRequests} from '../src/sidebarRequests';
afterEach(()=>vi.useRealTimers());
it('shares preload, click and poll requests, reuses fresh data and refreshes expired reads',async()=>{
 vi.useFakeTimers();
 const cache=createSidebarRequests(1000), load=vi.fn(async()=>['folder']);
 await Promise.all([cache.read('p',load),cache.read('p',load),cache.read('p',load,true)]);
 expect(load).toHaveBeenCalledTimes(1);
 await cache.read('p',load);expect(load).toHaveBeenCalledTimes(1);
 vi.advanceTimersByTime(1001);await cache.read('p',load);expect(load).toHaveBeenCalledTimes(2);
 await cache.read('p',load,true);expect(load).toHaveBeenCalledTimes(3);
});
it('does not cache failures and isolates pending reads across connection changes',async()=>{
 const cache=createSidebarRequests();
 const fail=vi.fn(async()=>{throw Error('offline');});
 await expect(cache.read('p',fail)).rejects.toThrow('offline');
 await expect(cache.read('p',fail)).rejects.toThrow('offline');
 expect(fail).toHaveBeenCalledTimes(2);
 let finish!:(v:string)=>void;
 const old=cache.read('p',()=>new Promise<string>(resolve=>finish=resolve));
 await Promise.resolve();cache.clear();
 await cache.read('p',async()=>'new');finish('old');await old;
 expect(await cache.read('p',async()=>'wrong')).toBe('new');
});
