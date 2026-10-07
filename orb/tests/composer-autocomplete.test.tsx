import { fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { expect, it, vi } from 'vitest';
import { Composer } from '../src/App';
import { loadAttachItems } from '../src/attach';
vi.mock('../src/attach', async importOriginal => ({ ...await importOriginal<typeof import('../src/attach')>(), loadAttachItems: vi.fn() }));
vi.mock('../src/api', async importOriginal => ({ ...await importOriginal<typeof import('../src/api')>(), isConnected: () => true }));
it('only opens context completion when matching results exist, including after a delayed load', async () => {
  let resolve!: (items: any[]) => void;
  vi.mocked(loadAttachItems).mockReturnValue(new Promise(r => { resolve = r; }));
  render(() => <Composer placeholder="Write" projectSlug="test" busy={false} onSend={() => {}} onStop={() => {}} />);
  const input = screen.getByPlaceholderText('Write');
  const type = (value: string) => fireEvent.input(input, { target: { value, selectionStart: value.length } });
  type('@');
  expect(screen.queryByRole('listbox', { name: 'Context' })).toBeNull();
  resolve([{id:'context:file',kind:'context',section:'Context',path:'context/file.txt',label:'file.txt'}]);
  await waitFor(() => expect(screen.getByRole('option').textContent).toContain('file.txt'));
  type('@missing');
  expect(screen.queryByRole('listbox', { name: 'Context' })).toBeNull();
  type('@file');
  expect(screen.getByRole('listbox', { name: 'Context' })).toBeTruthy();
});

it('shows only parent folders at the root of the + menu and drills into subfiles on click', async () => {
  vi.mocked(loadAttachItems).mockResolvedValue([
    { id: 'context:test:attachments/0ae513f9', kind: 'context', project: 'test', section: 'Folders', path: 'attachments/0ae513f9', label: 'attachments/0ae513f9/' },
    { id: 'context:test:attachments/0ae513f9/main.rs', kind: 'context', project: 'test', section: 'Files', path: 'attachments/0ae513f9/main.rs', label: 'attachments/0ae513f9/main.rs' },
    { id: 'context:test:context', kind: 'context', project: 'test', section: 'Folders', path: 'context', label: 'context/' },
    { id: 'context:test:context/AGENTS.md', kind: 'context', project: 'test', section: 'Files', path: 'context/AGENTS.md', label: 'context/AGENTS.md' },
  ]);
  render(() => <Composer placeholder="Write" projectSlug="test" busy={false} onSend={() => {}} onStop={() => {}} onAttachments={() => {}} />);
  await waitFor(() => expect(loadAttachItems).toHaveBeenCalledWith('test'));
  fireEvent.click(screen.getByTitle('Add context'));
  // Root shows parent folders (attachments/, context/) and no nested files.
  await waitFor(() => expect(screen.getByText('context/')).toBeTruthy());
  expect(screen.getByText('attachments/')).toBeTruthy();
  expect(screen.queryByText('AGENTS.md')).toBeNull();
  expect(screen.queryByText('context/AGENTS.md')).toBeNull();

  // Clicking context/ drills into its subfiles.
  fireEvent.click(screen.getByText('context/'));
  expect(screen.getByText('AGENTS.md')).toBeTruthy();
  fireEvent.click(screen.getByText('AGENTS.md'));
  expect((screen.getByPlaceholderText('Write') as HTMLTextAreaElement).value).toBe('@context/AGENTS.md ');
});

