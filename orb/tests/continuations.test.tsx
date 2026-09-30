import { cleanup, render, fireEvent, screen } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { createSignal } from 'solid-js';
import { MissionGlyph, missionStatusPresentation } from '../src/MissionGlyph';
import { actOnContinuation, continuationLabel, type ContinuationSummary } from '../src/continuations';
import { FolderActivityIcon } from '../src/FolderActivity';
afterEach(cleanup);
const wake: ContinuationSummary = {count:1,items:[{id:'wake-1',state:'scheduled',trigger:'time',next_at:'2030-10-30T13:30:00Z',reason:'Check the build'}]};
it('uses a ticking clock for a completed turn with a real scheduled continuation', () => {
 const [status,setStatus]=createSignal('awaiting_user');
 const {container}=render(()=><MissionGlyph status={status()} continuation={wake}/>);
 expect(container.querySelector('.wake-clock-hand')).not.toBeNull();
 expect(container.querySelector('.mission-status-spin')).toBeNull();
 setStatus('active');
 expect(container.querySelector('.mission-status-spin')).not.toBeNull();
 expect(container.querySelector('.wake-clock-hand')).toBeNull();
});
it('preserves permission and failure priority',()=>{
 expect(missionStatusPresentation('active',{id:'p',method:'permission'},wake).label).toBe('Approval requested');
 expect(missionStatusPresentation('failed',undefined,wake).label).toBe('Failed');
 expect(missionStatusPresentation('awaiting_user',undefined,wake).tone).toBe('scheduled');
});
it('distinguishes job waits, client waits, and unsynced requests',()=>{
 for (const [state,trigger,label] of [['scheduled','job','Will resume when the job finishes'],['pending_sync','time','Wake-up waiting to sync'],['waiting_for_client','delivery','Wake-up waiting for this computer']] as const) {
  expect(continuationLabel({count:1,items:[{id:'x',state,trigger}]})).toBe(label);
 }
});
it('shows details without opening the mission row',()=>{
 const row=vi.fn();
 const {getByRole}=render(()=><div onClick={row}><MissionGlyph status="awaiting_user" continuation={wake}/></div>);
 fireEvent.click(getByRole('button',{name:/View wake-ups/}));
 expect(row).not.toHaveBeenCalled();
 expect(screen.getByRole('dialog')).toBeTruthy();
 expect(screen.getByText('Check the build')).toBeTruthy();
 expect(screen.getByRole('button',{name:'Resume now'})).toBeTruthy();
});
it('prioritizes running descendants over scheduled descendants',()=>{
 const {container}=render(()=><FolderActivityIcon count={2} scheduled={1}/>);
 expect(container.querySelector('.mission-status-spin')).not.toBeNull();
 expect(container.querySelector('.wake-clock-hand')).toBeNull();
});

it('sends wake-up actions as JSON accepted by the API extractor',async()=>{
 const fetch=vi.fn().mockResolvedValue({ok:true,status:200,json:async()=>({ok:true})});
 vi.stubGlobal('fetch',fetch);
 try {
  await actOnContinuation('wake-1','cancel');
  expect(fetch.mock.calls[0][1].headers['Content-Type']).toBe('application/json');
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({action:'cancel'});
 } finally {vi.unstubAllGlobals();}
});
