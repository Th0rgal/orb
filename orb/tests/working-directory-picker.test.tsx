import {render,screen,fireEvent,waitFor} from '@solidjs/testing-library';
import {afterEach,it,expect,vi} from 'vitest';
import {WorkingDirectoryPicker} from '../src/WorkingDirectoryPicker';
afterEach(()=>{delete (window as any).__TAURI__;});
it('uses the native folder picker and keeps the selection on cancellation',async()=>{
 const invoke=vi.fn().mockResolvedValueOnce('/Users/test/repo').mockResolvedValueOnce(null);
 (window as any).__TAURI__={core:{invoke}};const change=vi.fn();
 render(()=><WorkingDirectoryPicker machine="local" value="/Users/test/old" onChange={change}/>);
 fireEvent.click(screen.getByRole('button',{name:'Choose working folder'}));
 await waitFor(()=>expect(change).toHaveBeenCalledWith('/Users/test/repo'));
 fireEvent.click(screen.getByRole('button',{name:'Choose working folder'}));
 await waitFor(()=>expect(invoke).toHaveBeenCalledTimes(2));
 expect(change).toHaveBeenCalledTimes(1);
});
it('edits remote paths without opening the local Finder',()=>{
 const invoke=vi.fn();(window as any).__TAURI__={core:{invoke}};const change=vi.fn();
 render(()=><WorkingDirectoryPicker machine="spark" value="" onChange={change}/>);
 fireEvent.click(screen.getByRole('button',{name:'Choose working folder'}));
 fireEvent.input(screen.getByLabelText('Folder path'),{target:{value:'/srv/project'}});
 expect(change).toHaveBeenCalledWith('/srv/project');expect(invoke).not.toHaveBeenCalled();
});
