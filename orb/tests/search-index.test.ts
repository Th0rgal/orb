import { describe, expect, it } from 'vitest';
import { markdownText } from '../src/Markdown';
import { indexText, matchOffsets, matchRange } from '../src/searchIndex';
import { userMessageText } from '../src/Transcript';

describe('searchIndex and message-only corpus helpers', () => {
  it('keeps block boundaries while matching across syntax tokens', () => {
    const scope = document.createElement('div');
    scope.innerHTML = '<p>hel<b>lo</b></p><p>world</p><button>hello</button>';
    document.body.append(scope);
    const index = indexText(scope);
    expect(matchOffsets(index.text, 'helloworld', false, false)).toHaveLength(0);
    const matches = matchOffsets(index.text, 'hello', false, false);
    expect(matches).toHaveLength(1);
    expect(matchRange(index, matches[0])?.toString()).toBe('hello');
    scope.remove();
  });

  it('supports literal special characters and full uncapped counts', () => {
    expect(matchOffsets('a.b axb', 'a.b', false, false)).toHaveLength(1);
    expect(matchOffsets('word '.repeat(6000), 'word', false, true)).toHaveLength(6000);
    expect(matchOffsets('Word wordy', 'word', false, true)).toHaveLength(1);
  });

  it('indexes only [data-find-message] subtrees and clickable file references when messagesOnly is true', () => {
    const scope = document.createElement('div');
    scope.innerHTML = `
      <div class="user"><small class="user-origin">Automatic</small><span data-find-message="">User Needle prompt</span><button>Edit</button></div>
      <div class="st-think open"><div class="st-think-body">Needle inside open thought</div></div>
      <div class="st-work"><div class="st-work-items"><div class="md">Needle inside work narration</div><div class="st-tool">Needle in tool</div></div></div>
      <div class="st-text"><div class="md" data-find-message=""><p>Agent answer in <button class="file-reference">src/Needle.ts</button></p></div></div>
    `;
    document.body.append(scope);
    const index = indexText(scope, { messagesOnly: true });
    const matches = matchOffsets(index.text, 'Needle', false, false);
    expect(matches).toHaveLength(2);
    expect(matchRange(index, matches[0])?.toString()).toBe('Needle');
    expect(matchRange(index, matches[1])?.toString()).toBe('Needle');
    expect(index.text).not.toContain('open thought');
    expect(index.text).not.toContain('work narration');
    expect(index.text).not.toContain('in tool');
    scope.remove();
  });

  it('aligns markdownText with rendered searchable Markdown including italics, tables, and citations', () => {
    const md = [
      'Check *italicNeedle* and **boldNeedle** in :codex-file-citation{label="src/find.ts" path="/work/src/find.ts"}.',
      '',
      '| ColA | ColB |',
      '| --- | --- |',
      '| alphaCell | betaCell |',
    ].join('\n');
    const plain = markdownText(md);
    expect(plain).toContain('italicNeedle');
    expect(plain).not.toContain('*italicNeedle*');
    expect(plain).toContain('find.ts');
    expect(plain).not.toContain('codex-file-citation');
    expect(matchOffsets(plain, 'alphaCellbetaCell', false, false)).toHaveLength(0);
    expect(matchOffsets(plain, 'betaCell', false, false)).toHaveLength(1);
  });

  it('excludes automatic coordinator wakeups, recovery notices, and resume prompts from userMessageText', () => {
    expect(userMessageText('Please refine search UX')).toBe('Please refine search UX');
    expect(userMessageText('Wake payload', 'background-task')).toBeNull();
    expect(userMessageText('Scheduled ping', 'scheduler')).toBeNull();
    expect(userMessageText('[Automatic recovery] Continuing run')).toBeNull();
    expect(
      userMessageText(
        'Your previous turn was interrupted before it finished. Check what is already done, then continue from there. Do not redo finished work.',
      ),
    ).toBeNull();
    expect(
      userMessageText(
        'Background task `t-1` (`pnpm test`) finished. (No captured output was available.)\n\nContinue from here.',
      ),
    ).toBeNull();
  });
});
