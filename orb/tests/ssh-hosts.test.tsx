import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { SshAddressBook } from "../src/SshAddressBook";
import { legacyAddresses, legacySshKey, sameAddress, validAddress } from "../src/sshHosts";
import { ApiError } from "../src/api";
const mocks = vi.hoisted(() => ({api: vi.fn()}));
vi.mock("../src/api", () => ({api: mocks.api, connectionVersion: () => 0, getApiUrl: () => "https://core.test", ApiError: class extends Error { constructor(public status: number, detail: string) { super(detail); } }}));
const address = {name:"Spark",host:"spark.local",user:"thomas",port:22,note:"GPU"};
const host = {...address,id:"a",revision:2};
beforeEach(() => { mocks.api.mockReset(); mocks.api.mockResolvedValue([host]); });
describe("shared SSH address book", () => {
  it("validates targets and deduplicates hosts without losing SSH users", () => {
    expect(validAddress(address)).toBe(true);
    expect(validAddress({...address,port:65536})).toBe(false);
    expect(validAddress({...address,host:"server; command"})).toBe(false);
    expect(sameAddress(address,{...address,host:"SPARK.local"})).toBe(true);
    expect(sameAddress(address,{...address,user:"root"})).toBe(false);
  });
  it("preserves malformed legacy storage and filters invalid addresses", () => {
    localStorage.setItem(legacySshKey, JSON.stringify([address,{...address,port:0}]));
    expect(legacyAddresses()).toEqual([address]);
    localStorage.setItem(legacySshKey,"broken");
    expect(legacyAddresses()).toEqual([]);
    expect(localStorage.getItem(legacySshKey)).toBe("broken");
  });
  it("imports missing targets after preview and keeps the old list", async () => {
    const second = {...address,host:"other.local"};
    localStorage.setItem(legacySshKey,JSON.stringify([address, second]));
    render(() => <SshAddressBook onUnsupported={() => {}} />);
    await fireEvent.click(await screen.findByText("Import 2 local addresses…"));
    expect(mocks.api.mock.calls.filter(([,o]) => o?.method === "POST")).toHaveLength(0);
    await fireEvent.click(screen.getByText("Import to this backend"));
    await waitFor(() => expect(localStorage.getItem("orb.sshHostsImported:https://core.test")).toBe("1"));
    const writes = mocks.api.mock.calls.filter(([,o]) => o?.method === "POST");
    expect(writes).toHaveLength(1); expect(JSON.parse(writes[0][1].body)).toEqual(second);
    expect(JSON.parse(localStorage.getItem(legacySshKey)!)).toHaveLength(2);
  });
  it("retains a failed draft and blocks stale writes until refresh", async () => {
    render(() => <SshAddressBook onUnsupported={() => {}} />);
    await fireEvent.click(await screen.findByText("Edit"));
    mocks.api.mockRejectedValueOnce(new ApiError(409,"Reload before editing"));
    await fireEvent.click(screen.getByText("Save"));
    await waitFor(() => expect((screen.getByText("Save") as HTMLButtonElement).disabled).toBe(true));
    expect(screen.getByDisplayValue("Spark")).toBeTruthy();
    const write = mocks.api.mock.calls.find(([,o]) => o?.method === "PUT");
    expect(JSON.parse(write![1].body).revision).toBe(2);
  });
  it("shows an offline snapshot as read-only", async () => {
    localStorage.setItem("orb.sshHosts:https://core.test",JSON.stringify([host]));
    mocks.api.mockRejectedValue(new Error("Offline"));
    render(() => <SshAddressBook onUnsupported={() => {}} />);
    await screen.findByText(/Could not refresh SSH addresses/);
    expect((screen.getByText("Edit") as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText("Add address") as HTMLButtonElement).disabled).toBe(true);
  });
});
