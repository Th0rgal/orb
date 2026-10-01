export type QuizQuestion = { number: string; text: string; choices: { letter: string; text: string }[] };
export type Quiz = { before: string; after: string; questions: QuizQuestion[] };
/** Only convert explicit numbered QCMs; never infer options or correct answers. */
export function parseQuiz(source: string): Quiz | undefined {
  if (!/\b(quiz|qcm)\b/i.test(source) || /```|~~~/.test(source)) return;
  const text = source.replace(/\r\n/g, '\n');
  const starts = [...text.matchAll(/^\s*(?:\*\*)?(\d+)[.)]\s+/gm)];
  if (!starts.length || starts.length > 30) return;
  const questions: QuizQuestion[] = [];
  let end = 0;
  for (let i = 0; i < starts.length; i++) {
    const start = starts[i];
    if (+start[1] !== i + 1) return;
    const from = start.index! + start[0].length;
    const block = text.slice(from, starts[i + 1]?.index ?? text.length);
    // A blank paragraph after options is prose, not another answer choice.
    const firstOption = /(?:^|\s)(?:\*\*)?A\)\s+/.exec(block);
    if (!firstOption) return;
    const tail = block.slice(firstOption.index);
    const paragraphEnd = /\n\s*\n(?=\s*(?!(?:\*\*)?[A-H]\)\s)\S)/.exec(tail);
    const optionsEnd = firstOption.index + (paragraphEnd?.index ?? tail.length);
    const optionsText = block.slice(firstOption.index, optionsEnd);
    const options = [...optionsText.matchAll(/(?:^|\s)(?:\*\*)?([A-H])\)\s+/g)];
    if (options.length < 2 || options.length > 8) return;
    const choices = options.map((option, j) => ({
      letter: option[1], text: optionsText.slice(option.index! + option[0].length, options[j + 1]?.index ?? optionsText.length).trim().replace(/^\*\*|\*\*$/g, '').trim(),
    }));
    if (choices.some((choice, j) => choice.letter !== String.fromCharCode(65 + j) || !choice.text)) return;
    const question = block.slice(0, firstOption.index).trim().replace(/^\*\*|\*\*$/g, '').trim();
    if (!question) return;
    // Preserve prose between questions by declining the transformation.
    if (i < starts.length - 1 && block.slice(optionsEnd).trim()) return;
    questions.push({number: start[1], text: question, choices});
    end = from + optionsEnd;
  }
  return {before: text.slice(0, starts[0].index).trim(), after: text.slice(end).trim(), questions};
}
