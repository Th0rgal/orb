import { createSignal } from "solid-js";

export function Toggle(p: { on: boolean; onClick?: () => void }) {
  const [on, setOn] = createSignal(p.on);
  return (
    <button
      class={`toggle ${on() ? "on" : ""}`}
      role="switch"
      aria-checked={on()}
      onClick={() => {
        setOn(!on());
        p.onClick?.();
      }}
    />
  );
}
