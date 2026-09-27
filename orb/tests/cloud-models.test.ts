import {expect,it} from 'vitest';
import {modelChoices} from '../src/CloudModelPicker';
import {navigationShortcuts,navigationShortcut} from '../src/keyboardShortcuts';
it('preserves Cursor parameter combinations and distinguishes the High variant',()=>{
 const rows=modelChoices([{id:'grok-4.6',displayName:'Grok 4.6',parameters:[{id:'effort',values:[{value:'high',displayName:'High'}]}],variants:[{params:[{id:'effort',value:'high'},{id:'fast',value:'false'}]}]}]);
 expect(rows[0].label).toBe('Grok 4.6 · High');
 expect(JSON.parse(rows[0].value).params).toEqual([{id:'effort',value:'high'},{id:'fast',value:'false'}]);
});
it('has unique section chords and respects focused controls',()=>{
 expect(new Set(navigationShortcuts.map(s=>s.code)).size).toBe(navigationShortcuts.length);
 expect(navigationShortcut(new KeyboardEvent('keydown',{code:'Digit2',key:'é',metaKey:true}))?.id).toBe('cloud-agent');
 expect(navigationShortcut(new KeyboardEvent('keydown',{code:'Digit2',metaKey:true,shiftKey:true}))).toBeUndefined();
});
