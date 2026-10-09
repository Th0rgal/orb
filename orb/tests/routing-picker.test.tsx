import { render, screen, fireEvent, cleanup } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { afterEach, expect, it, vi } from "vitest";
import { RoutingPicker } from "../src/RoutingPicker";

afterEach(cleanup);
it("filters suggestions, selects with the keyboard, and preserves custom IDs", () => {
  const changed = vi.fn();
  render(() => {
    const [value, setValue] = createSignal("");
    return <RoutingPicker label="Model" value={value()} options={[
      { id: "glm-5.3", name: "GLM 5.3" },
      { id: "glm-flash", name: "GLM Flash" },
      { id: "other", name: "Other" },
    ]} onInput={v => { setValue(v); changed(v); }} />;
  });
  const input = screen.getByRole("combobox");
  fireEvent.focus(input);
  fireEvent.input(input, { target: { value: "flash" } });
  expect(screen.getAllByRole("option")).toHaveLength(1);
  fireEvent.keyDown(input, { key: "ArrowDown" });
  fireEvent.keyDown(input, { key: "Enter" });
  expect(changed).toHaveBeenLastCalledWith("glm-flash");
  expect(screen.queryByRole("listbox")).toBeNull();
  fireEvent.input(input, { target: { value: "custom/model" } });
  expect(changed).toHaveBeenLastCalledWith("custom/model");
  expect(screen.getByText("No results")).toBeTruthy();
  fireEvent.input(input, { target: { value: "" } });
  fireEvent.keyDown(input, { key: "ArrowUp" });
  expect(screen.getAllByRole("option")[2].getAttribute("data-active")).toBe("true");
  fireEvent.keyDown(input, { key: "Escape" });
  expect(screen.queryByRole("listbox")).toBeNull();
});

it("shows distinct model IDs behind shared names and removes exact ID duplicates", () => {
  const onInput = vi.fn();
  render(() => <RoutingPicker label="Model" value="" onInput={onInput} options={[
    { id: "mistral-medium-latest", name: "mistral-medium-latest", detail: "Listed by provider" },
    { id: "mistral-medium-3.5", name: "mistral-medium-latest", detail: "Listed by provider" },
    { id: "mistral-vibe-cli-latest", name: "mistral-medium-latest", detail: "Listed by provider" },
    { id: "mistral-medium-latest", name: "mistral-medium-latest", detail: "Listed by provider" },
  ]} />);
  fireEvent.focus(screen.getByRole("combobox"));
  const choices = screen.getAllByRole("option");
  expect(choices).toHaveLength(3);
  expect(choices[1].textContent).toContain("mistral-medium-3.5");
  expect(choices[2].textContent).toContain("mistral-vibe-cli-latest");
  fireEvent.pointerDown(choices[1]);
  expect(onInput).toHaveBeenCalledWith("mistral-medium-3.5");
});
