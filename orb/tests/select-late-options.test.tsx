import { afterEach, expect, it } from "vitest";
import { cleanup, render } from "@solidjs/testing-library";
import { createSignal, For } from "solid-js";
import { Select } from "../src/Select";
afterEach(cleanup);
it("shows the requested value even when options arrive after it", async () => {
  const [opts, setOpts] = createSignal<string[]>([]);
  const { container } = render(() => <Select value="sensitive" aria-label="Project"><For each={opts()}>{o => <option value={o}>{o}</option>}</For></Select>);
  setOpts(["critical", "general", "sensitive"]);
  await new Promise(r => setTimeout(r, 0));
  const select = container.querySelector("select")!;
  expect(select.value).toBe("sensitive");
  expect(container.querySelector(".orb-select-label")!.textContent).toBe("sensitive");
});
