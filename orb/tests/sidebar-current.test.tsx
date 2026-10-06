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
  vi.stubGlobal("fetch", vi.fn(async (input: string, init?:RequestInit) => {
    const url = new URL(input), path = url.pathname;
    const id=path.split("/").at(-1);
    if(path.endsWith("/status") && init?.method === "POST") {
      const mid=path.split("/").at(-2);
      listed=listed.map(m=>m.id===mid?{...m,status:JSON.parse(String(init.body)).status}:m);
      return new Response(JSON.stringify({ok:true}));
    }
    if(path.startsWith("/api/control/missions/") && listed.some(m=>m.id===id)) return new Response(JSON.stringify(listed.find(m=>m.id===id)));

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

  it("reflects status transitions of the open conversation on its sidebar row immediately", async () => {
    listed = [{ ...mission, status: "active" }];
    const [current, setCurrent] = createSignal<Mission>({ ...mission, status: "active" });
    const view = render(() => <LiveProjectsSection currentMission={current()} selected={() => "m:restored"}
      harnessChoices={[]} onFork={() => {}} open={() => {}} onNewAgent={() => {}} onNewProject={() => {}} />);
    const row = await view.findByRole("button", { name: "Open plan", exact: true });
    expect(row.getAttribute("aria-description")).toBe("Running");
    setCurrent({ ...mission, status: "interrupted" });
    await waitFor(() => expect(view.getByRole("button", { name: "Open plan", exact: true }).getAttribute("aria-description")).toBe("Interrupted"));
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

it("does not duplicate an archived parent around its visible child",async()=>{
 const parent={...mission,id:"parent",title:"Archived parent",status:"acknowledged"};
 const child={...mission,parent_mission_id:"parent"}; listed=[parent,child];
 const view=render(()=><LiveProjectsSection currentMission={child} selected={()=>"m:restored"} harnessChoices={[]} onFork={()=>{}} open={()=>{}} onNewAgent={()=>{}} onNewProject={()=>{}}/>);
 await view.findByRole("button",{name:"Archived parent",exact:true});
 fireEvent.click(view.getByRole("button",{name:"Archived",exact:true}));
 await waitFor(()=>expect(view.getAllByRole("button",{name:"Archived parent",exact:true})).toHaveLength(1));
});

it("shift selection exposes Archive and archives each selected idle conversation",async()=>{
 const second={...mission,id:"second",title:"Other plan"};listed=[mission,second];
 const view=render(()=><LiveProjectsSection currentMission={mission} selected={()=>"m:restored"} harnessChoices={[]} onFork={()=>{}} open={()=>{}} onNewAgent={()=>{}} onNewProject={()=>{}}/>);
 const first=await view.findByRole("button",{name:"Open plan",exact:true}),other=await view.findByRole("button",{name:"Other plan",exact:true});
 fireEvent.click(first);fireEvent.click(other,{shiftKey:true});fireEvent.contextMenu(other,{clientX:20,clientY:30});
 fireEvent.click(await view.findByRole("menuitem",{name:"Archive 2 conversations",exact:true}));
 await waitFor(()=>expect(listed.every(m=>m.status==="acknowledged")).toBe(true));
 expect(vi.mocked(fetch).mock.calls.filter(([url,init])=>String(url).endsWith("/status")&&init?.method==="POST")).toHaveLength(2);
});
