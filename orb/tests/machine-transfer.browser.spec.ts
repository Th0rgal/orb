import { test, expect } from "@playwright/test";
test("moves from the footer with an inventory and no automatic execution", async ({ page }) => {
  const calls: string[] = [];
  let selection: unknown;
  const action = { id: "move", mission_id: "test", phase: "preparing", source: { kind: "core" }, destination: { kind: "node", id: "spark" }, backend: "codex", model: "model", created_at: "", manifest: null as unknown };
  await page.route("**/api/control/missions/test/machine-transfer", async route => {
    const body = route.request().postDataJSON();
    let result: unknown;
    if (route.request().method() === "GET") result = { version: 1, actions: [], destinations: [{ machine: { kind: "core" }, label: "Core", available: true }, { machine: action.destination, label: "Spark", available: true, harnesses: ["codex"] }] };
    else {
      calls.push(body.op === "files" ? body.operation.op : body.op);
      if (body.op === "prepare") result = action;
      else if (body.operation?.op === "inventory") result = { bytes: 93, files: 5, truncated: false, protected: 1, limits: { bytes: 100, files: 10 }, rows: [
        { path: "notes.txt", folder: false, state: "moved", bytes: 3, files: 1 },
        { path: "data", folder: true, state: "moved", bytes: 90, files: 4 }, { path: "data/raw", folder: true, state: "moved", bytes: 80, files: 3 },
        { path: "target", folder: true, state: "rebuildable", bytes: 50, files: 2 }] }
      else if (body.operation?.op === "select") { selection = body.operation; result = { ok: true }; }
      else if (body.operation?.op === "snapshot") { action.manifest = { files: [{ path: "notes.txt", bytes: 3, executable: false, sha256: "hash" }, ...Array.from({ length: 150 }, (_, i) => ({ path: `folder${i}/file`, bytes: 0, executable: false, sha256: "hash" }))], bytes: 3, excluded: [".env", "node_modules"], links: [{ path: "bin/cargo", target: "rustup" }], skipped: [{ path: "context", reason: "link points outside the workspace" }] }; action.phase = "copying"; result = action; }
      else if (body.operation?.op === "read") result = { data: "YWJj" };
      else if (body.operation?.op === "stage") result = { received: {}, sealed: false };
      else if (body.operation?.op === "verify") { action.phase = "verified"; result = action; }
      else if (body.op === "activate") { action.phase = "activated"; result = action; }
      else result = { ok: true };
    }
    await route.fulfill({ json: result });
  });
  await page.route("**/api/control/missions/test", route => route.fulfill({ json: { id: "test", status: "awaiting_user", machine_transfer: action } }));
  await page.goto("/tests/machine-transfer.html");
  await page.getByRole("button", { name: "Change machine: Core" }).click();
  await expect(page.getByRole("menuitem", { name: /Core/ })).toBeDisabled();
  await page.getByRole("menuitem", { name: "Spark ›" }).click();
  await expect(page.getByRole("dialog", { name: "Change machine" })).toBeVisible();
  await page.getByRole("button", { name: "Prepare transfer" }).click();
  const choose = page.getByRole("region", { name: "Choose what to move" });
  await expect(choose.getByText("93 B of 100 B")).toBeVisible();
  await choose.getByLabel("Move target").check();
  await expect(choose.getByText("Too large to move")).toBeVisible();
  await expect(page.getByRole("button", { name: "Continue" })).toBeDisabled();
  await choose.locator("summary").click({ position: { x: 6, y: 12 } });
  await choose.getByLabel("Move data/raw").uncheck();
  await expect(choose.getByText("63 B of 100 B")).toBeVisible();
  await expect(choose.getByText("4 of 10")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  const inventory = page.getByRole("region", { name: "Workspace inventory" });
  await expect(inventory.locator(".transfer-group")).toHaveCount(100);
  await expect(inventory.getByText("and 51 smaller folders")).toBeVisible();
  await inventory.getByText("1 file · 3 B").click();
  await expect(inventory.getByText("notes.txt")).toBeVisible();
  await expect(inventory.getByText("context")).toBeVisible();
  await expect(inventory.getByText("link points outside the workspace")).toBeVisible();
  await inventory.locator("summary", { hasText: "Links" }).click();
  await expect(inventory.getByText("→ rustup")).toBeVisible();
  await inventory.locator("summary", { hasText: "Excluded" }).click();
  await expect(inventory.getByText(".env", { exact: true })).toBeVisible();
  await page.screenshot({ path: "artifacts/machine-transfer-review.png" });
  await page.getByRole("button", { name: "Move to Spark" }).click();
  await expect(page.getByRole("button", { name: "Change machine: Spark" })).toBeVisible();
  expect([...new Set(calls)]).toEqual(["prepare", "inventory", "select", "snapshot", "stage", "read", "write", "verify", "activate"]);
  expect(selection).toEqual({ op: "select", omit: ["data/raw"], include: ["target"] });
});
