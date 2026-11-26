import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
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
 fireEvent.click(await screen.findByRole("menuitem",{name:"Archive 2 conversations",exact:true}));
 await waitFor(()=>expect(listed.every(m=>m.status==="acknowledged")).toBe(true));
 expect(vi.mocked(fetch).mock.calls.filter(([url,init])=>String(url).endsWith("/status")&&init?.method==="POST")).toHaveLength(2);
});

it("keeps an open mission only at its moved destination across delayed lists and stale details", async () => {
  const { moveOptimistically, missionMoveKey, movedMission, resetMoves } = await import('../src/moves');
  resetMoves();
  listed = [mission];
  let releaseOldList!:()=>void;
  const oldList = new Promise<void>(resolve=>releaseOldList=resolve);
  const fetcher = vi.mocked(fetch);
  fetcher.mockImplementation(async (input) => {
    const url = new URL(String(input)), path = url.pathname;
    if (path.endsWith('/missions') && url.searchParams.get('project') === 'verity') await oldList;
    const body = path === '/api/projects' ? {projects:[{slug:'verity',title:'Verity'},{slug:'other',title:'Other'}]}
      : path.endsWith('/files') ? {entries:[]}
      : path.endsWith('/controller') ? {job:null,runs:[]}
      : path.endsWith('/crons') ? {jobs:[]}
      : path.endsWith('/missions') ? (url.searchParams.get('project') === 'other' ? [] : listed) : [];
    return new Response(JSON.stringify(body));
  });
  const view = render(() => <LiveProjectsSection currentMission={movedMission(mission)} selected={() => 'm:restored'}
    harnessChoices={[]} onFork={()=>{}} open={()=>{}} onNewAgent={()=>{}} onNewProject={()=>{}} />);
  await view.findByRole('button',{name:'Open plan',exact:true});
  let release!:()=>void;
  const gate = new Promise<void>(r=>release=r);
  const done = moveOptimistically(missionMoveKey(mission.id), {kind:'mission',fromProject:'verity',toProject:'other',path:''}, async()=>{
    await gate;
    const { applyServerPlacementEvent } = await import('../src/missionMove');
    applyServerPlacementEvent([{ mission_id: mission.id, project: 'other', folder: '', placement_revision: 2 }]);
  });
  await waitFor(()=>expect(view.getAllByRole('button',{name:'Open plan',exact:true})).toHaveLength(1));
  release(); await done;
  releaseOldList();
  await new Promise(r=>setTimeout(r,20));
  expect(view.getAllByRole('button',{name:'Open plan',exact:true})).toHaveLength(1);
  // Clearing the transient overlay must not resurrect the stale open detail.
  resetMoves();
  await waitFor(()=>expect(view.getAllByRole('button',{name:'Open plan',exact:true})).toHaveLength(1));
  const projects = view.container.querySelectorAll('.row.project.contains-current');
  expect([...projects].map(el=>el.getAttribute('data-drop-project'))).toEqual(['other']);
});

it("rolls back a rejected native Archive on B and keeps A open", async () => {
  const target = { ...mission, id: "other", title: "Other conversation" };
  listed = [mission, target];
  const fetchFixture = globalThis.fetch;
  vi.stubGlobal("fetch", async (input: string, init?: RequestInit) => {
    if (new URL(input).pathname.endsWith("/other/status") && init?.method === "POST")
      return new Response(JSON.stringify({ error: "Archive refused by Core" }), { status: 409 });
    return fetchFixture(input, init);
  });
  const open = vi.fn(), status = vi.fn(), error = vi.fn();
  const [requests, setRequests] = createSignal<{ mission: Mission; restore: boolean }[]>([]);
  render(() => <LiveProjectsSection headless currentMission={mission} activityMissions={listed}
    selected={() => "m:" + mission.id} open={open} harnessChoices={[]} onFork={() => {}}
    onNewAgent={() => {}} onNewProject={() => {}} archiveRequests={requests()}
    onArchiveRequestsHandled={() => setRequests([])} onArchiveError={error} onArchiveStatus={status} />);
  setRequests([{ mission: target, restore: false }]);
  await waitFor(() => expect(error).toHaveBeenCalledWith(target.id, false, expect.any(String)));
  expect(status.mock.calls.map(([rows]) => rows.map((row: Mission) => [row.id, row.status])))
    .toEqual([[[target.id, "acknowledged"]], [[target.id, target.status]]]);
  expect(open).not.toHaveBeenCalled();
});

describe("newly started missions in the sidebar", () => {
  const baseMission = {
    id: "existing-1",
    title: "Existing task",
    project: "verity",
    status: "completed",
    tags: [],
    history: [],
    created_at: "2026-11-25T10:00:00Z",
    updated_at: "2026-11-25T10:00:00Z",
  } as Mission;

  it("shows a newly started mission immediately in an already-loaded project even when the project list cache is warm", async () => {
    listed = [baseMission];
    const [activity, setActivity] = createSignal<Mission[]>([]);
    const reported: Mission[][] = [];
    const view = render(() => (
      <LiveProjectsSection
        activityMissions={activity()}
        currentMission={baseMission}
        selected={() => "m:existing-1"}
        onProjectMissions={(_slug, rows) => reported.push(rows)}
        harnessChoices={[]}
        onFork={() => {}}
        open={() => {}}
        onNewAgent={() => {}}
        onNewProject={() => {}}
      />
    ));
    await view.findByRole("button", { name: "Existing task", exact: true });
    await waitFor(() => expect(reported.length).toBeGreaterThan(0));

    // Server list still hasn't been invalidated (simulates 10s read cache or backend lag),
    // and activityMissions transitions from empty [] -> [started].
    const started = {
      ...baseMission,
      id: "newly-started",
      title: "Fix Android app",
      status: "active",
      created_at: "2026-11-26T10:00:00Z",
      updated_at: "2026-11-26T10:00:00Z",
    } as Mission;
    setActivity([started]);

    await view.findByRole("button", { name: "Fix Android app", exact: true });
    expect(reported.at(-1)?.some(m => m.id === "newly-started")).toBe(true);
  });

  it("keeps a newly started mission when a stale in-flight project list resolves without it", async () => {
    listed = [baseMission];
    let releaseFirstList!: () => void;
    const firstListGate = new Promise<void>(resolve => { releaseFirstList = resolve; });
    let listCalls = 0;
    const fetcher = vi.mocked(fetch);
    fetcher.mockImplementation(async (input) => {
      const url = new URL(String(input)), path = url.pathname;
      if (path.endsWith("/missions") && url.searchParams.get("project") === "verity") {
        listCalls++;
        if (listCalls <= 2) await firstListGate;
      }
      const body = path === "/api/projects" ? { projects: [{ slug: "verity", title: "Verity" }] }
        : path.endsWith("/files") ? { entries: [] }
        : path.endsWith("/controller") ? { job: null, runs: [] }
        : path.endsWith("/crons") ? { jobs: [] }
        : path.endsWith("/missions") ? listed : [];
      return new Response(JSON.stringify(body), { status: 200 });
    });

    const [activity, setActivity] = createSignal<Mission[]>([]);
    const view = render(() => (
      <LiveProjectsSection
        activityMissions={activity()}
        selected={() => null}
        harnessChoices={[]}
        onFork={() => {}}
        open={() => {}}
        onNewAgent={() => {}}
        onNewProject={() => {}}
      />
    ));
    const project = await view.findByRole("button", { name: "Verity", exact: true });
    fireEvent.click(project);

    const started = {
      ...baseMission,
      id: "race-started",
      title: "Started mid-fetch",
      status: "active",
      created_at: "2026-11-26T10:01:00Z",
      updated_at: "2026-11-26T10:01:00Z",
    } as Mission;
    setActivity([started]);
    await view.findByRole("button", { name: "Started mid-fetch", exact: true });

    // Stale initial project list resolves without `started`.
    releaseFirstList();
    await new Promise(r => setTimeout(r, 30));
    expect(view.getByRole("button", { name: "Started mid-fetch", exact: true })).toBeTruthy();
  });

  it("does not insert /btw or archived-by-tag missions from activityMissions into the project list", async () => {
    listed = [baseMission];
    const [activity, setActivity] = createSignal<Mission[]>([baseMission]);
    const view = render(() => (
      <LiveProjectsSection
        activityMissions={activity()}
        currentMission={baseMission}
        selected={() => "m:existing-1"}
        harnessChoices={[]}
        onFork={() => {}}
        open={() => {}}
        onNewAgent={() => {}}
        onNewProject={() => {}}
      />
    ));
    await view.findByRole("button", { name: "Existing task", exact: true });

    const btw = { ...baseMission, id: "btw-1", title: "Side question", status: "active", tags: ["btw-subagent"] } as Mission;
    const archivedTag = { ...baseMission, id: "arch-1", title: "Tagged archived", status: "completed", tags: ["archived"] } as Mission;
    setActivity([baseMission, btw, archivedTag]);
    await new Promise(r => setTimeout(r, 30));

    expect(view.queryByRole("button", { name: "Side question", exact: true })).toBeNull();
    expect(view.queryByRole("button", { name: "Tagged archived", exact: true })).toBeNull();
  });
});
