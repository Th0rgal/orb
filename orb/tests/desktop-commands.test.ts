import { afterEach, describe, expect, it, vi } from "vitest";
import { startDesktopCommandListener, type DesktopCommandPayload } from "../src/desktopCommands";

describe("startDesktopCommandListener", () => {
  const origWindow = globalThis.window;

  afterEach(() => {
    if (origWindow === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.window;
    } else {
      globalThis.window = origWindow;
    }
  });

  it("dispatches providers-refresh, new-agent, and open-page commands once per id", async () => {
    let listener: ((ev: { payload: DesktopCommandPayload }) => void) | undefined;
    const unlisten = vi.fn();

    globalThis.window = {
      __ORB_DESKTOP__: {
        event: {
          listen: vi.fn(async (name: string, cb: (ev: { payload: DesktopCommandPayload }) => void) => {
            expect(name).toBe("orb-desktop-command");
            listener = cb;
            return unlisten;
          }),
        },
      },
    } as unknown as Window & typeof globalThis;

    const onProvidersRefresh = vi.fn();
    const onNewAgent = vi.fn();
    const onOpenPage = vi.fn();

    const stop = startDesktopCommandListener({
      onProvidersRefresh,
      onNewAgent,
      onOpenPage,
    });
    await Promise.resolve();
    expect(listener).toBeTypeOf("function");

    listener!({ payload: { id: "cmd-1", action: "providers-refresh" } });
    listener!({ payload: { id: "cmd-1", action: "providers-refresh" } });
    expect(onProvidersRefresh).toHaveBeenCalledTimes(1);

    listener!({
      payload: {
        id: "cmd-2",
        action: "new-agent",
        backend: "claudecode",
        prompt: "Review this NixOS config",
        cwd: "/home/thomas/work/nixos",
      },
    });
    expect(onNewAgent).toHaveBeenCalledWith({
      backend: "claudecode",
      prompt: "Review this NixOS config",
      cwd: "/home/thomas/work/nixos",
    });

    listener!({ payload: { id: "cmd-3", action: "open-page", page: "providers" } });
    expect(onOpenPage).toHaveBeenCalledWith("providers");

    stop();
    expect(unlisten).toHaveBeenCalledTimes(1);
  });
});
