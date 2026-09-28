import {render, screen, fireEvent, cleanup, waitFor} from '@solidjs/testing-library';
import {afterEach, expect, it, vi} from 'vitest';
import {createSignal} from 'solid-js';
import {parseQuiz} from '../src/quiz';
import {QuizAnswer} from '../src/QuizAnswer';
afterEach(cleanup);
const text = `Oui.\n\n## Quiz de test\n\n**1. Combien font 7 × 8 ?** A) 48   B) 56   C) 64\n\n**2. Quel mot est un verbe ?** A) Rapidement B) Maison C) Apprendre\n\n**3. Tous les chats sont des mammifères. Félix est un chat. Que peut-on conclure ?** A) Félix est un mammifère. B) Tous les mammifères sont des chats. C) Félix n’est pas un mammifère.\n\nRéponds avec le numéro et la lettre pour chaque question, et je te donnerai ton score.`;
it('preserves the screenshot questions, choices, intro and outro without inventing answers', () => {
 const q=parseQuiz(text)!;
 expect(q.questions).toHaveLength(3);
 expect(q.questions[0].text).toBe('Combien font 7 × 8 ?');
 expect(q.questions[2].choices[2].text).toBe('Félix n’est pas un mammifère.');
 expect(q.before).toContain('Oui.');expect(q.after).toContain('Réponds');
 expect(parseQuiz('Quiz\n1. Question A) one C) three')).toBeUndefined();
 expect(parseQuiz('Ordinary list\n1. Question A) one B) two')).toBeUndefined();
 expect(parseQuiz('Quiz\n```\n1. Question A) one B) two\n```')).toBeUndefined();
});
it('accepts multiline choices and preserves paragraph fallback',()=>{
 expect(parseQuiz('Quiz\n1. Question ?\nA) One\nB) Two\n\n2. Another ?\nA) Three\nB) Four')?.questions).toHaveLength(2);
 expect(parseQuiz('Quiz\n1. Question A) One B) Two\n\nUnrelated prose\n\n2. Other A) X B) Y')).toBeUndefined();
});
it('retains selections through refresh, navigation and failed sends, then submits exactly once',async()=>{
 const send=vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true);
 const [source,setSource]=createSignal(text);
 render(()=><QuizAnswer text={source()} disabled={false} onSubmit={send} fallback={<p>Plain response</p>}/>);
 expect((screen.getByRole('button',{name:'Suivant →'}) as HTMLButtonElement).disabled).toBe(true);
 fireEvent.click(screen.getByRole('radio',{name:'B 56'}));
 setSource(text);
 fireEvent.click(screen.getByRole('button',{name:'Suivant →'}));
 fireEvent.click(screen.getByRole('radio',{name:'C Apprendre'}));
 fireEvent.click(screen.getByRole('button',{name:'Question précédente'}));
 expect((screen.getByRole('radio',{name:'B 56'}) as HTMLInputElement).checked).toBe(true);
 fireEvent.click(screen.getByRole('button',{name:'Question suivante'}));
 fireEvent.click(screen.getByRole('button',{name:'Suivant →'}));
 fireEvent.click(screen.getByRole('radio',{name:'A Félix est un mammifère.'}));
 fireEvent.click(screen.getByRole('button',{name:'Envoyer mes réponses'}));
 await screen.findByRole('alert');
 expect(send.mock.calls[0][0]).toBe('Mes réponses au quiz :\n1. B) 56\n2. C) Apprendre\n3. A) Félix est un mammifère.');
 fireEvent.click(screen.getByRole('button',{name:'Envoyer mes réponses'}));
 await waitFor(()=>expect(screen.getByRole('status').textContent).toBe('Réponses envoyées'));
 expect((screen.getByRole('button',{name:'Envoyer mes réponses'}) as HTMLButtonElement).disabled).toBe(true);
 expect(send).toHaveBeenCalledTimes(2);
});
it('leaves ordinary responses untouched and disables historical quiz submission',()=>{
 const r=render(()=><QuizAnswer text="Hello" disabled={false} onSubmit={vi.fn()} fallback={<p>Original markdown</p>}/>);
 expect(screen.getByText('Original markdown')).toBeTruthy();r.unmount();
 render(()=><QuizAnswer text={text} disabled={true} onSubmit={vi.fn()} fallback={null}/>);
 expect(screen.getByRole('radio',{name:'A 48'}).closest('fieldset')?.disabled).toBe(true);
});
