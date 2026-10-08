import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { Transcript, buildTranscript } from "../src/Transcript";
import type { StreamEvent } from "../src/stream";

const ev = (type: string, data: Record<string, unknown>): StreamEvent => ({ type, data });

describe("thinking fold", () => {
  it("shows one Thinking header and the thought text, not a nested work fold", () => {
    const items = buildTranscript([
      ev("thinking", { content: "Need to inspect the kernel.", done: false }),
    ]);
    const { container } = render(() => <Transcript items={items} />);
    const heads = container.querySelectorAll(".st-think-head");
    expect(heads).toHaveLength(1);
    expect(heads[0].textContent).toMatch(/^Thinking/);
    expect(container.querySelectorAll(".st-work")).toHaveLength(0);
    expect(container.querySelector(".st-think-body")?.textContent).toBe("Need to inspect the kernel.");
  });

  it("keeps tools in a work fold and inlines thought text without a second Thinking header", () => {
    const items = buildTranscript([
      ev("thinking", { content: "I'll read the file.", done: true }),
      ev("tool_call", { tool_call_id: "a", name: "read", args: { path: "guard.ts" } }),
    ]);
    const { container } = render(() => <Transcript items={items} />);
    expect(container.querySelectorAll(".st-work-head")).toHaveLength(1);
    expect(container.querySelectorAll(".st-think-head")).toHaveLength(0);
    container.querySelector<HTMLButtonElement>(".st-work-head")!.click();
    expect(container.querySelector(".st-think-body")?.textContent).toBe("I'll read the file.");
    expect(container.querySelector(".st-tool-name")?.textContent).toBe("read");
  });

  it("auto-collapses completed standalone thoughts and formats inline code and bold when expanded", () => {
    const items = buildTranscript([
      ev("thinking", { content: "Checking `src/styles.css` and **MissionDock**.", done: true }),
    ]);
    const { container } = render(() => <Transcript items={items} />);
    expect(container.querySelector(".st-think-body")).toBeNull();
    container.querySelector<HTMLButtonElement>(".st-think-head")!.click();
    const body = container.querySelector(".st-think-body");
    expect(body).not.toBeNull();
    expect(body?.querySelector("code")?.textContent).toBe("src/styles.css");
    expect(body?.querySelector("strong")?.textContent).toBe("MissionDock");
  });

  it("folds consecutive earlier thoughts into a collapsible count row while keeping the latest thought visible", () => {
    const items = buildTranscript([
      ev("thinking", { content: "First thought", done: true }),
      ev("thinking", { content: "Second thought", done: true }),
      ev("thinking", { content: "Current thought in progress", done: false }),
    ]);
    const { container } = render(() => <Transcript items={items} />);
    const fold = container.querySelector<HTMLButtonElement>(".st-think-fold .st-work-head");
    expect(fold?.textContent).toBe("2 thoughts");
    expect(container.querySelectorAll(".st-think-head")).toHaveLength(1);
    expect(container.querySelector(".st-think-body")?.textContent).toBe("Current thought in progress");

    fold!.click();
    expect(container.querySelectorAll(".st-think-head")).toHaveLength(3);
  });
});

it("latest checklist is visible outside folded raw work, with real progress and no Plan/Build control",()=>{
  const items=buildTranscript([
    ev("tool_call",{tool_call_id:"old",name:"TodoWrite",args:{todos:[{content:"Old task",status:"pending",activeForm:"Working"}]}}),
    ev("tool_call",{tool_call_id:"new",name:"update_plan",args:{plan:[{step:"Plan a build",status:"completed"},{step:"Check result",status:"in_progress"}]}}),
    ev("tool_call",{tool_call_id:"bad",name:"todowrite",args:{todos:[{content:"Invented",status:"maybe"}]}}),
  ]);
  const {container}=render(()=><Transcript items={items}/>);
  expect(container.querySelectorAll('.st-work-body')).toHaveLength(0);
  expect(container.querySelector('.mission-tasks')?.textContent).toContain('1/2 completed');
  expect(container.querySelector('.mission-tasks')?.textContent).not.toContain('Old task');
  expect(container.querySelector('.mission-tasks')?.textContent).not.toContain('Invented');
  expect(container.querySelector('progress')?.value).toBe(1);
  container.querySelector<HTMLButtonElement>('.st-work-head')!.click();
  expect(container.querySelectorAll('.st-tool')).toHaveLength(3);
  expect([...container.querySelectorAll('button')].some(button=>['Plan','Build'].includes(button.textContent??''))).toBe(false);

  const afterFollowUp=buildTranscript([
    ev("tool_call",{tool_call_id:"new",name:"update_plan",args:{plan:[{step:"Plan a build",status:"completed"}]}}),
    ev("assistant_message",{content:"Merged PR #486."}),
    ev("user_message",{id:"u2",content:"Can we ask them to contact us before starting?"}),
    ev("assistant_message",{content:"Yes, you can add a pre-registration clause."}),
  ]);
  const {container:followUpContainer}=render(()=><Transcript items={afterFollowUp}/>);
  expect(followUpContainer.querySelector('.mission-tasks')).toBeNull();
});

it("allows collapsing and dismissing a completed checklist to reclaim conversation space", () => {
  const items = buildTranscript([
    ev("tool_call", {
      tool_call_id: "done-list",
      name: "todowrite",
      args: {
        todos: [
          { content: "First step", status: "completed", priority: "high" },
          { content: "Second step", status: "completed", priority: "medium" },
        ],
      },
    }),
  ]);
  const { container } = render(() => <Transcript items={items} />);
  expect(container.querySelector(".mission-tasks")).not.toBeNull();
  const toggle = container.querySelector<HTMLButtonElement>(".tasks-heading-toggle")!;
  toggle.click();
  expect(container.querySelector(".mission-tasks.collapsed")).not.toBeNull();
  expect(container.querySelector(".mission-tasks ol")).toBeNull();
  toggle.click();
  expect(container.querySelector(".mission-tasks ol")).not.toBeNull();
  const dismiss = container.querySelector<HTMLButtonElement>(".tasks-dismiss")!;
  expect(dismiss).not.toBeNull();
  dismiss.click();
  expect(container.querySelector(".mission-tasks")).toBeNull();
});

it("renders diff badges, argument badges, and bash output formatting inside tool rows", () => {
  const items = buildTranscript([
    ev("tool_call", {
      tool_call_id: "edit-1",
      name: "edit",
      args: { filePath: "src/App.tsx", oldString: "a\nb", newString: "a\nc\nd" },
    }),
    ev("tool_result", { tool_call_id: "edit-1", name: "edit", result: "Edit applied" }),
    ev("tool_call", {
      tool_call_id: "read-1",
      name: "read",
      args: { filePath: "src/Transcript.tsx", offset: 10, limit: 50 },
    }),
    ev("tool_result", { tool_call_id: "read-1", name: "read", result: "10: line" }),
    ev("tool_call", {
      tool_call_id: "bash-1",
      name: "bash",
      args: { command: "pnpm test" },
    }),
    ev("tool_result", { tool_call_id: "bash-1", name: "bash", result: "All tests passed" }),
  ]);
  const { container } = render(() => <Transcript items={items} />);
  expect(container.querySelector(".st-work-head .st-diff-add")?.textContent).toBe("+2");
  expect(container.querySelector(".st-work-head .st-diff-del")?.textContent).toBe("-1");
  container.querySelector<HTMLButtonElement>(".st-work-head")!.click();
  expect([...container.querySelectorAll(".st-tool-badge")].map(el => el.textContent)).toEqual(["offset=10", "limit=50"]);
  const bashHead = [...container.querySelectorAll<HTMLButtonElement>(".st-tool-head")].find(b => b.textContent?.includes("bash"))!;
  bashHead.click();
  expect(container.querySelector(".st-bash-cmd")?.textContent).toBe("$ pnpm test");
  expect(container.querySelector(".st-tool-bash")?.textContent).toContain("All tests passed");
});
