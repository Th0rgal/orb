import { For, Show, createMemo, createSignal, createEffect, createUniqueId, type JSX } from 'solid-js';
import { MdView } from './Markdown';
import { parseQuiz } from './quiz';
import './quiz.css';
export function QuizAnswer(p: {text: string; disabled: boolean; onSubmit: (text: string) => Promise<boolean>; fallback: JSX.Element}) {
  const group = createUniqueId();
  const quiz = createMemo(() => parseQuiz(p.text));
  const [index, setIndex] = createSignal(0), [answers, setAnswers] = createSignal<Record<string,string>>({});
  const [sending, setSending] = createSignal(false), [sent, setSent] = createSignal(false), [error, setError] = createSignal('');
  createEffect(() => { p.text; setIndex(0); setAnswers({}); setSent(false); setError(''); });
  const question = () => quiz()!.questions[index()];
  const locked = () => p.disabled || sending() || sent();
  const submit = async () => {
    const q = quiz();
    if (!q || locked() || q.questions.some(item => !answers()[item.number])) return;
    const text = 'Mes réponses au quiz :\n' + q.questions.map(item => `${item.number}. ${answers()[item.number]}) ${item.choices.find(c => c.letter === answers()[item.number])!.text}`).join('\n');
    setSending(true); setError('');
    try { if (await p.onSubmit(text)) setSent(true); else setError('Envoi non confirmé. Tes réponses sont conservées.'); }
    catch { setError('Envoi non confirmé. Tes réponses sont conservées.'); }
    finally { setSending(false); }
  };
  return <Show when={quiz()} fallback={p.fallback}>
    <MdView compact text={quiz()!.before}/>
    <section class="native-question quiz-card" aria-label="Quiz interactif">
      <div class="quiz-top"><span aria-live="polite">Question {index()+1} / {quiz()!.questions.length}</span><div>
        <button aria-label="Question précédente" disabled={index()===0 || sending()} onClick={() => setIndex(index()-1)}>←</button>
        <button aria-label="Question suivante" disabled={index()===quiz()!.questions.length-1 || sending()} onClick={() => setIndex(index()+1)}>→</button>
      </div></div>
      <fieldset disabled={locked()}><legend><MdView compact text={question().text}/></legend>
        <For each={question().choices}>{choice => <label class="native-choice quiz-choice" classList={{selected:answers()[question().number]===choice.letter}}>
          <input type="radio" name={`${group}-${question().number}`} checked={answers()[question().number]===choice.letter} onChange={() => setAnswers({...answers(),[question().number]:choice.letter})}/>
          <span class="native-choice-key">{choice.letter}</span><span class="native-choice-copy"><MdView compact text={choice.text}/></span><span class="native-choice-check" aria-hidden="true">✓</span>
        </label>}</For>
      </fieldset>
      <div class="native-question-actions quiz-bottom"><span role="status">{sent() ? 'Réponses envoyées' : `${Object.keys(answers()).length} / ${quiz()!.questions.length} réponses`}</span>
        <Show when={index() < quiz()!.questions.length-1} fallback={<button class="s-btn native-primary quiz-next" disabled={locked() || Object.keys(answers()).length !== quiz()!.questions.length} onClick={() => void submit()}>{sending() ? 'Envoi…' : 'Envoyer mes réponses'}</button>}>
          <button class="s-btn native-primary quiz-next" disabled={!answers()[question().number] || sending()} onClick={() => setIndex(index()+1)}>Suivant →</button>
        </Show>
      </div>
      <Show when={error()}><p role="alert">{error()}</p></Show>
    </section>
    <Show when={quiz()!.after}><MdView compact text={quiz()!.after}/></Show>
  </Show>;
}
