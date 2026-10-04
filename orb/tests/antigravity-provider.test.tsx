import { render, fireEvent, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { AntigravityProvider } from "../src/AntigravityProvider";
import * as api from "../src/api";
afterEach(() => vi.restoreAllMocks());
function setup(models: [string,string][]) {
  vi.spyOn(api, "getRemoteNodes").mockResolvedValue({enabled:true,nodes:[{id:"old-agent"}] as api.RemoteNodeView[]});
  const discovery=vi.spyOn(api,"listNodeAntigravityModels").mockResolvedValue(models);
  const ui=render(() => <AntigravityProvider/>);
  fireEvent.click(ui.getByRole("button",{name:/Antigravity CLI/}));
  return {ui,discovery};
}
it("shows Argon only when discovered for the selected native account",async()=>{
 const {ui,discovery}=setup([["agy-demo","Gemini 4 Argon"]]);
 await waitFor(()=>expect(ui.getByRole("list",{name:"Antigravity models"}).textContent).toContain("Gemini 4 Argon"));
 expect(ui.queryByText("Gemini CLI")).toBeNull();
 discovery.mockResolvedValueOnce([["flash","Gemini Flash"]]);
 await waitFor(()=>expect(ui.getByRole("option",{name:"old-agent"})).toBeTruthy());
 fireEvent.change(ui.getByLabelText("Antigravity machine"),{target:{value:"old-agent"}});
 await waitFor(()=>expect(ui.getByText("Gemini Flash")).toBeTruthy());
 expect(ui.queryByText("Gemini 4 Argon")).toBeNull();
 expect(discovery).toHaveBeenLastCalledWith("old-agent");
});
it("clears account models when refreshed discovery fails",async()=>{
 const {ui,discovery}=setup([["agy-demo","Gemini 4 Argon"]]);
 await waitFor(()=>expect(ui.getByText("Gemini 4 Argon")).toBeTruthy());
 discovery.mockRejectedValueOnce(new Error("unavailable"));
 fireEvent.click(ui.getByRole("button",{name:"Refresh account"}));
 await waitFor(()=>expect(ui.getByText("Account unavailable")).toBeTruthy());
 expect(ui.queryByText("Gemini 4 Argon")).toBeNull();
});
it("ignores a late response from the previous machine",async()=>{
 let finish!: (rows:[string,string][])=>void;
 const {ui,discovery}=setup([]);
 await waitFor(()=>expect(ui.getByText("No models available")).toBeTruthy());
 discovery.mockReturnValueOnce(new Promise(resolve=>{finish=resolve;}));
 fireEvent.click(ui.getByRole("button",{name:"Refresh account"}));
 discovery.mockResolvedValueOnce([["node-model","Node model"]]);
 fireEvent.change(ui.getByLabelText("Antigravity machine"),{target:{value:"old-agent"}});
 await waitFor(()=>expect(ui.getByText("Node model")).toBeTruthy());
 finish([["agy-demo","Gemini 4 Argon"]]);
 await Promise.resolve();
 expect(ui.queryByText("Gemini 4 Argon")).toBeNull();
});
it("reloads the machine inventory when the backend changes",async()=>{
 const {ui}=setup([["agy-demo","Gemini 4 Argon"]]);
 await waitFor(()=>expect(ui.getByRole("option",{name:"old-agent"})).toBeTruthy());
 fireEvent.change(ui.getByLabelText("Antigravity machine"),{target:{value:"old-agent"}});
 vi.mocked(api.getRemoteNodes).mockResolvedValueOnce({enabled:true,nodes:[{id:"new-node"}] as api.RemoteNodeView[]});
 api.bumpConnectionVersion(value=>value+1);
 await waitFor(()=>expect(ui.getByRole("option",{name:"new-node"})).toBeTruthy());
 expect(ui.queryByRole("option",{name:"old-agent"})).toBeNull();
 expect((ui.getByLabelText("Antigravity machine") as HTMLSelectElement).value).toBe("core");
});
