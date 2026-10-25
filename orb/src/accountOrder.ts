/**
 * Account priority within one provider: the backend tries a provider's
 * accounts in `priority` order (lower first) before the next chain step.
 */
export type OrderedAccount = { id: string; provider_type: string; priority?: number };

/** Accounts grouped by provider (first appearance), each group by priority. */
export function orderAccounts<T extends OrderedAccount>(list: readonly T[]): T[] {
  const groups = new Map<string, { item: T; index: number }[]>();
  list.forEach((item, index) => {
    const group = groups.get(item.provider_type) ?? [];
    group.push({ item, index });
    groups.set(item.provider_type, group);
  });
  return [...groups.values()].flatMap(group =>
    group.sort((a, b) => (a.item.priority ?? 0) - (b.item.priority ?? 0) || a.index - b.index).map(g => g.item));
}

/** Ids of `id`'s provider in order once it moves to position `to` among them; null when nothing moves. */
export function moveAccount(list: readonly OrderedAccount[], id: string, to: number): string[] | null {
  const moved = list.find(a => a.id === id);
  if (!moved) return null;
  const ids = orderAccounts(list).filter(a => a.provider_type === moved.provider_type).map(a => a.id);
  const from = ids.indexOf(id);
  if (to < 0 || to >= ids.length || to === from) return null;
  ids.splice(to, 0, ...ids.splice(from, 1));
  return ids;
}

/** `list` with the given provider order applied as priorities 0..n. */
export function applyOrder<T extends OrderedAccount>(list: readonly T[], ids: readonly string[]): T[] {
  const rank = new Map(ids.map((id, i) => [id, i]));
  return list.map(a => (rank.has(a.id) ? { ...a, priority: rank.get(a.id)! } : a));
}
