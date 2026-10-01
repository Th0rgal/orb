import {UserTurn} from "../src/Transcript";
import {describe,it,expect} from 'vitest';
import {render,screen,cleanup,fireEvent} from '@solidjs/testing-library';
import {afterEach} from 'vitest';
import {AutomaticReminder,reminderMessages,nextReminder} from '../src/AutomaticReminder';
import type {StreamItem} from '../src/transcriptModel';
afterEach(cleanup);
const tool:StreamItem={kind:'tool',key:'t',callId:'t',name:'ScheduleWakeup',args:{prompt:'Check workers',delaySeconds:1800},result:{noop:true},done:true};
describe('automatic reminders',()=>{
 it('attributes legacy reminders only to successful preceding exact tool prompts',()=>{
  const rows:StreamItem[]=[tool,{kind:'user',key:'u',text:'Check workers'},{kind:'user',key:'v',text:'Check workers'}];
  expect(reminderMessages(rows).get('u')).toEqual({origin:'Scheduled by Claude',seconds:1800});
  expect(reminderMessages(rows).has('v')).toBe(false);
  expect(reminderMessages([{...tool,result:{error:'failed'}},rows[1]]).size).toBe(0);
  expect(reminderMessages([tool,{...rows[1],source:'api:user'} as StreamItem]).size).toBe(0);
 });
 it('shows scheduled messages without guessing the author',()=>{
  expect(reminderMessages([{kind:'user',key:'u',text:'Check',source:'scheduler'}]).get('u')).toEqual({origin:'Mission scheduler'});
 });
 it('keeps instructions collapsed without editing or resend controls',()=>{
  const {container}=render(()=><AutomaticReminder text="Full instructions" reminder={{origin:'Scheduled by Claude',seconds:1800}}/>);
  expect(container.querySelector('details')?.open).toBe(false);
  expect(screen.getByText('Full instructions')).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Send again'})).toBeNull();
  expect(screen.queryByRole('button',{name:'Edit prompt'})).toBeNull();
 });
 it('shows only unfired active one-shot reminders',()=>{
  const wake={active:true,trigger:{type:'interval',seconds:1800},stop_policy:{type:'after_first_fire'},created_at:'2026-09-30T10:00:00Z'};
  expect(nextReminder([wake])).toBe(Date.parse('2026-09-30T10:30:00Z'));
  expect(nextReminder([{...wake,last_triggered_at:'2026-09-30T10:05:00Z'}])).toBe(Date.parse('2026-09-30T10:35:00Z'));
  expect(nextReminder([{...wake,active:false,last_triggered_at:'2026-09-30T10:30:00Z'}])).toBeUndefined();
 });
});

it('keeps the automatic follow-up label mounted when entering and leaving edit mode', async()=>{
 const {container}=render(()=><UserTurn text="Check worker progress" source="idle-worker-watchdog"/>);
 const label=screen.getByText('↻ Automatic follow-up');
 await fireEvent.dblClick(container.querySelector('.user')!);
 expect(screen.getByText('↻ Automatic follow-up')).toBe(label);
 expect(label.nextElementSibling?.classList.contains('prompt-editor')).toBe(true);
 await fireEvent.click(screen.getByRole('button',{name:'Cancel',exact:true}));
 expect(screen.getByText('↻ Automatic follow-up')).toBe(label);
});
