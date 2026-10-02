import {render,screen,fireEvent,cleanup} from '@solidjs/testing-library';
import {afterEach,describe,it,expect} from 'vitest';
import {CyberPicker,cyberCompatibility,draftCyber,setDraftCyber} from '../src/cyberAccess';
import {describeError} from '../src/ErrorNotice';
afterEach(()=>{cleanup();setDraftCyber('standard');});
describe('cyber selection',()=>{
 it('starts Standard and never calls a pending selection active',()=>{
  expect(draftCyber()).toBe('standard');
  render(()=><CyberPicker value="daybreak" model="gpt-6.1-sol" onChange={()=>{}}/>);
  expect(screen.getByText('requested')).toBeTruthy();
  expect(screen.queryByText('active')).toBeNull();
 });
 it('keeps the model and requires an explicit selection',async()=>{
  let selected='';render(()=><CyberPicker value="standard" model="gpt-6.1-sol" onChange={v=>selected=v}/>);
  await fireEvent.click(screen.getByRole('button',{name:'Cyber program: Standard'}));
  await fireEvent.click(screen.getByRole('menuitemradio',{name:/Daybreak/}));
  expect(selected).toBe('daybreak');
 });
 it('disables incompatible choices and explains why',()=>{
  expect(cyberCompatibility('daybreak','unknown-model')).toContain('not been established');
  expect(cyberCompatibility('standard','gpt-daybreak-blue-latest')).toContain('requires Daybreak');
  expect(cyberCompatibility('daybreak','gpt-6-astra')).toBeUndefined();
 });
 it('preserves access denial and cyber policy as distinct errors',()=>{
  expect(describeError('403 access_program_not_enabled').title).toBe('Cyber access is not enabled');
  expect(describeError('cyberPolicy').title).toContain('policy');
  expect(describeError('unsupported_access_program').title).toContain('unsupported');
 });
});
