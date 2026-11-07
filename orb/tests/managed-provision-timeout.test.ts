import { afterEach, describe, expect, it, vi } from "vitest";
import { createMission, MANAGED_PROVISION_TIMEOUT_MS, setConnection } from "../src/api";
import { createManagedMachine } from "../src/managedMachineModel";
import { desktopHost, nativeInvoke } from "../src/native";

describe("managed machine cold-boot timeout & native desktop host resolution", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    delete (window as unknown as Record<string, unknown>).__ORB_DESKTOP__;
    delete (window as unknown as Record<string, unknown>).__TAURI__;
  });

  it("uses MANAGED_PROVISION_TIMEOUT_MS (9 min) for auto-managed boat.dev mission launches instead of 30s", async () => {
    setConnection("https://orb.example", "jwt-test");
    const timeoutSpy = vi.spyOn(AbortSignal, "timeout");
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ id: "m-boat", title: "Boat mission", status: "active" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await createMission({
      title: "Boat launch",
      remote_node_id: "auto-managed:boat:small",
    });

    expect(MANAGED_PROVISION_TIMEOUT_MS).toBeGreaterThanOrEqual(540_000);
    expect(timeoutSpy).toHaveBeenCalledWith(MANAGED_PROVISION_TIMEOUT_MS);
  });

  it("uses MANAGED_PROVISION_TIMEOUT_MS when provisioning a managed machine directly", async () => {
    setConnection("https://orb.example", "jwt-test");
    const timeoutSpy = vi.spyOn(AbortSignal, "timeout");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            id: "vm-1",
            name: "boat-1",
            provider: "boat",
            status: "ready",
            hourly_usd: 0.12,
            idle_stop_minutes: 30,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );

    await createManagedMachine({
      provider: "boat",
      preset_id: "small",
      wait: true,
    });

    expect(timeoutSpy).toHaveBeenCalledWith(MANAGED_PROVISION_TIMEOUT_MS);
  });

  it("prefers window.__ORB_DESKTOP__ over legacy window.__TAURI__", async () => {
    const orbInvoke = vi.fn(async () => "from-orb-desktop");
    const legacyInvoke = vi.fn(async () => "from-tauri");
    (window as unknown as Record<string, unknown>).__ORB_DESKTOP__ = {
      core: { invoke: orbInvoke },
    };
    (window as unknown as Record<string, unknown>).__TAURI__ = {
      core: { invoke: legacyInvoke },
    };

    expect(desktopHost()?.core?.invoke).toBe(orbInvoke);
    expect(await nativeInvoke()?.("local_machine_identity")).toBe("from-orb-desktop");
    expect(legacyInvoke).not.toHaveBeenCalled();
  });
});
