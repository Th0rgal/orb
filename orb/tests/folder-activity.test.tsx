import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen } from '@solidjs/testing-library';
import { createSignal } from 'solid-js';
import { folderActivity, FolderActivityIcon } from '../src/FolderActivity';
import type { Mission } from '../src/api';
afterEach(cleanup);
const mission = (id: string, status: string, path = '', project = 'verity') => ({id, status, project, tags: [`orb-folder:${path}`]} as Mission);
it('counts nested activity on all ancestors without leaking to siblings or projects', () => {
 const m = mission('one','active','proofs/nested');
 const counts = folderActivity([m,m,mission('two','running','proofs-other'),mission('three','completed','proofs'),mission('four','paused'),mission('five','awaiting_user'),mission('six','queued'),mission('seven','waiting_background','proofs','other')]);
 expect([...counts.get('verity')!]).toEqual([['',2],['proofs',1],['proofs/nested',1],['proofs-other',1]]);
 expect(counts.get('other')?.get('')).toBe(1);
 expect(folderActivity([mission('one','completed','proofs/nested')]).size).toBe(0);
});
it('keeps the folder color and removes the overlay when work ends', () => {
 const [count,setCount] = createSignal(2);
 const {container} = render(() => <FolderActivityIcon expanded={false} color="red" count={count()} />);
 expect(screen.getByRole('img',{name:'2 agents running inside'})).toBeTruthy();
 expect((container.firstChild as HTMLElement).style.color).toBe('red');
 setCount(0);
 expect(screen.queryByRole('img')).toBeNull();
 expect(container.querySelector('svg')).toBeTruthy();
});
