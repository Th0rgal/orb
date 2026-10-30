export function Toggle(p: { on: boolean; label?: string; disabled?: boolean; onClick?: () => void }) {
  return (
    <button
      type="button"
      class={`toggle ${p.on ? "on" : ""}`}
      role="switch"
      aria-label={p.label}
      aria-checked={p.on}
      disabled={p.disabled}
      onClick={() => p.onClick?.()}
    />
  );
}
