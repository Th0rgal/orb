import { render, cleanup } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { afterEach, expect, it } from "vitest";
import { MissionGlyph, missionStatusPresentation } from "../src/MissionGlyph";

afterEach(cleanup);

it("shows one status icon in place of the bot glyph and its badge", () => {
  const [status, setStatus] = createSignal("active");
  const { container } = render(() => <MissionGlyph status={status()} />);
  const icons = () => container.querySelectorAll(".mission-glyph > svg");
  expect(icons()).toHaveLength(1);
  expect(container.querySelector(".mission-glyph > svg.mission-status-spin")).not.toBeNull();
  expect(container.querySelector(".mission-status-mark")).toBeNull();
  setStatus("completed");
  expect(container.querySelector(".mission-glyph")?.getAttribute("title")).toBe("Completed");
  expect(icons()).toHaveLength(1);
  expect(container.querySelector(".mission-status-spin")).toBeNull();
  for (const state of ["idle", "blocked", "paused", "failed", "interrupted", "unrecognized"]) {
    setStatus(state);
    expect(container.querySelector(".success")).toBeNull();
    expect(icons()).toHaveLength(1);
    expect(container.querySelector(".mission-status-spin")).toBeNull();
    expect(container.querySelector(".mission-status-mark")).toBeNull();
  }
});

 it.each(['awaiting_user','waiting_user','acknowledged'])('renders %s as ready, without implying a question or success',status=>{
  const {container}=render(()=><MissionGlyph status={status}/>);
  expect(container.querySelector('.mission-glyph')?.getAttribute('title')).toBe('Ready for a follow-up');
  expect(container.querySelector('.mission-status-mark')).toBeNull();
 });
 it('only explicit pending interactions request attention',()=>{
  expect(missionStatusPresentation('active',{id:'q',method:'questions'}).label).toBe('Waiting for your reply');
  expect(missionStatusPresentation('active',{id:'p',method:'permission'}).label).toBe('Approval requested');
  expect(missionStatusPresentation('completed',{id:'old',method:'questions'}).label).toBe('Completed');
 });

it('keeps cloud identity and its status badge together', () => {
  const {container} = render(() => <MissionGlyph status="active" identity={<span data-testid="provider">Cloud</span>} />);
  expect(container.querySelector('.mission-glyph [data-testid="provider"]')).not.toBeNull();
  expect(container.querySelector('.mission-glyph .mission-status-spin')).not.toBeNull();
});
