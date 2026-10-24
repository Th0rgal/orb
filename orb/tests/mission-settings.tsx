import { render } from "solid-js/web";
import { createSignal, Show } from "solid-js";
import { MissionSettings } from "../src/MissionSettings";
import type { MissionBudget } from "../src/missionBudget";
import "../src/styles.css";
// Test data only: a root agent with a $10 pool, one pooled and one
// sub-budget subagent. `?mode=none` starts with the budget off;
// `?refuse=1` makes every save fail (rollback).
const q = new URLSearchParams(location.search);
if (q.get("theme")) document.documentElement.dataset.theme = q.get("theme")!;
const titles: Record<string, string> = { c1: "CPU probe (small)", c2: "Audit lean-native", root: "Snark.fast campaign" };
let current: MissionBudget = q.get("mode") === "none"
  ? { mission_id: "root", own_budget_usd: null, pool_id: null, mode: "none", pool: null, max_grant_usd: null, children: [] }
  : {
    mission_id: "root", own_budget_usd: 10, pool_id: "root", mode: "own", max_grant_usd: null,
    pool: { pool_id: "root", budget_usd: 10, spent_usd: 1.6021, reserved_usd: 0.4, carved_usd: 2, available_usd: 5.9979, live_machines: 2 },
    children: [
      { mission_id: "c1", mode: "pooled", budget_usd: null, spent_usd: 0.031, reserved_usd: 0.018 },
      { mission_id: "c2", mode: "sub_budget", budget_usd: 2, spent_usd: 0.42, reserved_usd: 0.2 },
    ],
  };
const wait = (ms: number) => new Promise(r => setTimeout(r, ms));
function App() {
  const [open, setOpen] = createSignal(true);
  return <main style={{ height: "100vh", background: "var(--bg)" }}>
    <button onClick={() => setOpen(true)}>Open settings</button>
    <Show when={open()}>
      <MissionSettings missionId="root" title={titles.root} titleOf={id => titles[id]} onClose={() => setOpen(false)}
        load={async () => { await wait(50); return current; }}
        save={async (_id, amount) => {
          await wait(150);
          if (q.get("refuse")) throw new Error("sub_budget_exceeds_pool: Sub-budget exceeds what the parent pool can grant ($1.0000 remaining)");
          current = amount == null
            ? { ...current, own_budget_usd: null, mode: "none", pool: null, pool_id: null }
            : { ...current, own_budget_usd: amount, mode: "own", pool_id: "root",
                pool: { pool_id: "root", budget_usd: amount, spent_usd: current.pool?.spent_usd ?? 0, reserved_usd: current.pool?.reserved_usd ?? 0, carved_usd: current.pool?.carved_usd ?? 0,
                  available_usd: amount - (current.pool ? current.pool.spent_usd + current.pool.reserved_usd + current.pool.carved_usd : 0), live_machines: 0 } };
          return current;
        }} />
    </Show>
  </main>;
}
render(() => <App />, document.getElementById("root")!);
