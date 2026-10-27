import {describe,it,expect,vi,afterEach} from 'vitest';
import {render,cleanup} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';

const wake={active:true,trigger:{type:'interval',seconds:1800},stop_policy:{type:'after_first_fire'},created_at:new Date().toISOString()};
const api=vi.fn(async()=>[wake]);
vi.mock('../src/api',()=>({api:(...a:unknown[])=>api(...(a as [])),connectionVersion:()=>0,isConnected:()=>true}));
const {NextReminder}=await import('../src/AutomaticReminder');

afterEach(()=>{cleanup();api.mockClear();});

describe('next reminder',()=>{
 it('shows a pending wake-up for a live mission',async()=>{
  const {findByText}=render(()=><NextReminder mission="m" busy={false}/>);
  expect(await findByText(/Next reminder at/)).toBeTruthy();
 });
 it('stays put while the mission refreshes and when a poll fails',async()=>{
  // Mission 6bcb4fff: the line blinked on every mission refresh.
  const [archived,setArchived]=createSignal<boolean|undefined>(false);
  const {findByText,container}=render(()=><NextReminder mission="m" busy={false} archived={archived()}/>);
  await findByText(/Next reminder at/);
  setArchived(undefined);
  expect(container.textContent).toContain('Next reminder');
  api.mockRejectedValueOnce(new Error('offline'));
  await new Promise(r=>setTimeout(r,0));
  expect(container.textContent).toContain('Next reminder');
  expect(api).toHaveBeenCalledTimes(1);
 });
 it('is hidden and not fetched for an archived mission',async()=>{
  const {container}=render(()=><NextReminder mission="m" busy={false} archived/>);
  await new Promise(r=>setTimeout(r,0));
  expect(api).not.toHaveBeenCalled();
  expect(container.textContent).not.toContain('Next reminder');
 });
});
