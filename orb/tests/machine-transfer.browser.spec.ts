import { test, expect } from "@playwright/test";
test("moves from the footer with an inventory and no automatic execution", async ({ page }) => {
  const calls: string[] = [];
  const action = { id: "move", mission_id: "test", phase: "preparing", source: { kind: "core" }, destination: { kind: "node", id: "spark" }, backend: "codex", model: "model", created_at: "", manifest: null as unknown };
  await page.route("**/api/control/missions/test/machine-transfer", async route => {
    const body = route.request().postDataJSON();
    let result: unknown;
    if (route.request().method() === "GET") result = { version: 1, actions: [], destinations: [{ machine: { kind: "core" }, label: "Core", available: true }, { machine: action.destination, label: "Spark", available: true, harnesses: ["codex"] }] };
    else {
      calls.push(body.op === "files" ? body.operation.op : body.op);
      if (body.op === "prepare") result = action;
      else if (body.operation?.op === "snapshot") { action.manifest = { files: [{ path: "notes.txt", bytes: 3, executable: false, sha256: "hash" }], bytes: 3, excluded: [".env", "node_modules"], links: [{ path: "bin/cargo", target: "rustup" }], skipped: [{ path: "context", reason: "link points outside the workspace" }] }; action.phase = "copying"; result = action; }
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
  const inventory = page.getByRole("region", { name: "Workspace inventory" });
  await expect(inventory.getByText("1 file · 3 B")).toBeVisible();
  await expect(inventory.getByText("context")).toBeVisible();
  await expect(inventory.getByText("link points outside the workspace")).toBeVisible();
  await inventory.locator("summary", { hasText: "Links" }).click();
  await expect(inventory.getByText("→ rustup")).toBeVisible();
  await inventory.locator("summary", { hasText: "Excluded" }).click();
  await expect(inventory.getByText(".env", { exact: true })).toBeVisible();
  await page.screenshot({ path: "artifacts/machine-transfer-review.png" });
  await page.getByRole("button", { name: "Move to Spark" }).click();
  await expect(page.getByRole("button", { name: "Change machine: Spark" })).toBeVisible();
  expect(calls).toEqual(["prepare", "snapshot", "stage", "read", "write", "verify", "activate"]);
});
