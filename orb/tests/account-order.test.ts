import { describe, expect, it } from "vitest";
import { applyOrder, moveAccount, orderAccounts } from "../src/accountOrder";

const list = [
  { id: "ag-1", provider_type: "antigravity", priority: 0 },
  { id: "an-1", provider_type: "anthropic", priority: 1 },
  { id: "ag-2", provider_type: "antigravity", priority: 1 },
  { id: "an-2", provider_type: "anthropic", priority: 0 },
  { id: "k", provider_type: "kimi" },
];

describe("account order", () => {
  it("groups by provider and sorts each group by priority", () => {
    expect(orderAccounts(list).map(a => a.id)).toEqual(["ag-1", "ag-2", "an-2", "an-1", "k"]);
  });

  it("keeps the listed order for equal priorities", () => {
    const flat = [{ id: "b", provider_type: "x" }, { id: "a", provider_type: "x" }];
    expect(orderAccounts(flat).map(a => a.id)).toEqual(["b", "a"]);
  });

  it("moves an account within its own provider only", () => {
    expect(moveAccount(list, "ag-2", 0)).toEqual(["ag-2", "ag-1"]);
    expect(moveAccount(list, "an-1", 0)).toEqual(["an-1", "an-2"]);
    expect(moveAccount(list, "ag-1", 0)).toBeNull();
    expect(moveAccount(list, "ag-1", 2)).toBeNull();
    expect(moveAccount(list, "k", 1)).toBeNull();
    expect(moveAccount(list, "missing", 0)).toBeNull();
  });

  it("applies a new order optimistically as priorities", () => {
    const next = orderAccounts(applyOrder(list, ["ag-2", "ag-1"]));
    expect(next.map(a => a.id)).toEqual(["ag-2", "ag-1", "an-2", "an-1", "k"]);
    expect(list[0].priority).toBe(0);
  });
});
