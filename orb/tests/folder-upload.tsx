import { render } from 'solid-js/web';
import { Composer } from '../src/composer/Composer';
import { saveComposerDraft } from '../src/composerDrafts';
import '../src/styles.css';

// Mission on a remote node (old-agent) with shared project context, as in the bug report.
const PATH = 'attachments/497dfe42-8ff1-44a8-b0f8-6b74a4866833/Questões_PPLA_air_Law_key (1).pdf';
const w = window as any;
w.sent = [];
document.documentElement.dataset.theme = new URLSearchParams(location.search).get('theme') ?? 'dark';
const scope = `m:${location.search.includes('restored') ? 'restored' : 'fresh'}`;
const start = async () => {
  if (location.search.includes('restored')) {
    // A draft saved before the app restarted: the original file handle is gone.
    await saveComposerDraft(scope, { text: `Explique @"${PATH}" por favor`, images: [], uploads: [{ source: { name: 'Questões_PPLA_air_Law_key (1).pdf', localPath: '/Users/t/Downloads/Questões_PPLA_air_Law_key (1).pdf' }, path: PATH, destination: 'context:pilot', connection: 0, endpoint: 'https://previous-backend.example' }] });
  }
  render(() => <main style={{ padding: '30px', 'max-width': '760px', margin: 'auto' }}>
    <Composer scope={scope} projectSlug="pilot" uploadTarget="old-agent" placeholder="Reply" busy={false} onSend={(text) => { w.sent.push(text); return true; }} onStop={() => {}} />
  </main>, document.getElementById('root')!);
};
void start();
