export const MATH_REPLY = [
  "## Rare boundary",
  "- Dans `word_math.rs`, le bug ne se produit que lorsque :",
  String.raw`  $$2^{64} - 9\,999 \le \text{amount} + \text{fee} \le 2^{64} - 1\,617$$`,
  String.raw`- Sur $2^{64} \approx 1.84 \times 10^{19}$ valeurs possibles, seules **$8\,383$ valeurs** déclenchent le bug :`,
  String.raw`  - Un fuzzer aléatoire a une chance sur $2 \times 10^{15}$ de tomber dessus.`,
].join("\n");
