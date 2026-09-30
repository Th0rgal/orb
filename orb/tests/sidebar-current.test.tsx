import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, waitFor } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { LiveProjectsSection } from "../src/ProjectFiles";
import { SidebarTree } from "../src/Tree";
import { clearConnection, setConnection, type Mission } from "../src/api";

const mission = { id: "restored", title: "Open plan", project: "verity", status: "interrupted", tags: [], history: [], created_at: "", updated_at: "" } as Mission;
let listed: Mission[] = [];
beforeEach(() => {
  listed = [];
  vi.stubGlobal("fetch", vi.fn(async (input: string) => {
    const path = new URL(input).pathname;
    const body = path === "/api/projects" ? { projects: [{ slug: "verity", title: "Verity" }] }
      : path.endsWith("/files") ? { entries: [] }
      : path.endsWith("/controller") ? { job: null, runs: [] }
      : path.endsWith("/crons") ? { jobs: [] } : path.endsWith("/missions") ? listed : [];
    return new Response(JSON.stringify(body), { status: 200 });
  }));
  Element.prototype.scrollIntoView = vi.fn();
  setConnection("http://sidebar.test", "fixture");
});
afterEach(() => { clearConnection(); vi.unstubAllGlobals(); });

describe("open conversation in the sidebar", () => {
  it("reveals restored details arriving after the list, even outside its first page", async () => {
    const [current, setCurrent] = createSignal<Mission>();
    const view = render(() => <LiveProjectsSection currentMission={current()} selected={() => "m:restored"}
      harnessChoices={[]} onFork={() => {}} open={() => {}} onNewAgent={() => {}} onNewProject={() => {}} />);
    const project = await view.findByRole("button", { name: "Verity", exact: true });
    expect(project.getAttribute("aria-expanded")).toBe("false");
    setCurrent(mission);
    await waitFor(() => expect(project.getAttribute("aria-expanded")).toBe("true"));
    const row = await view.findByRole("button", { name: "Open plan", exact: true });
    expect(row.getAttribute("aria-current")).toBe("page");
    fireEvent.click(project);
    setCurrent({ ...mission, status: "paused" });
    expect(project.getAttribute("aria-expanded")).toBe("false");
    expect(view.getByText("Open")).toBeTruthy();
  });

  it("reopens a previously collapsed parent when navigating back to its child", async () => {
    const parent = { ...mission, id: "parent", title: "Parent" };
    const child = { ...mission, parent_mission_id: "parent" };
    listed = [parent, child];
    const [selected, select] = createSignal<string | null>("m:restored");
    const view = render(() => <LiveProjectsSection currentMission={child} selected={selected}
      harnessChoices={[]} onFork={() => {}} open={select} onNewAgent={() => {}} onNewProject={() => {}} />);
    const row = await view.findByRole("button", { name: "Parent", exact: true });
    await waitFor(() => expect(row.getAttribute("aria-expanded")).toBe("true"));
    fireEvent.click(view.getByRole("button", { name: "Hide the 1 mission launched by Parent" }));
    expect(row.getAttribute("aria-expanded")).toBe("false");
    select(null);
    select("m:restored");
    await waitFor(() => expect(row.getAttribute("aria-expanded")).toBe("true"));
    expect(view.getByRole("button", { name: "Open plan", exact: true }).getAttribute("aria-current")).toBe("page");
  });

  it("distinguishes the open conversation from a different multi-selected row", async () => {
    const view = render(() => <SidebarTree label="Test" selected="open" selectedIds={["other"]}
      nodes={[{ id: "open", data: "Open" }, { id: "other", data: "Other" }]}
      render={row => <button>{row.data}</button>} />);
    const rows = await view.findAllByRole("treeitem");
    expect(rows[0].getAttribute("aria-current")).toBe("page");
    expect(rows[0].getAttribute("aria-selected")).toBe("false");
    expect(rows[1].getAttribute("aria-current")).toBeNull();
    expect(rows[1].getAttribute("aria-selected")).toBe("true");
  });
});
