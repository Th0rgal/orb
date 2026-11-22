import { afterEach, describe, expect, it, vi } from "vitest";
import { render } from "@solidjs/testing-library";
import { useOverlayPosition } from "../src/overlayPosition";

describe("useOverlayPosition point anchoring", () => {
  const cleanups: Array<() => void> = [];
  const origInnerWidth = window.innerWidth;
  const origInnerHeight = window.innerHeight;
  const origResizeObserver = globalThis.ResizeObserver;

  afterEach(() => {
    for (const c of cleanups.splice(0)) c();
    Object.defineProperty(window, "innerWidth", { value: origInnerWidth, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: origInnerHeight, configurable: true });
    globalThis.ResizeObserver = origResizeObserver;
  });

  function mountPointOverlay(point: { x: number; y: number }, size: { width: number; height: number }) {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    } as unknown as typeof ResizeObserver;

    let capturedEl!: HTMLDivElement;
    const { unmount } = render(() => {
      let el!: HTMLDivElement;
      const style = useOverlayPosition(() => el, {
        point: () => point,
        width: () => size.width,
      });
      return (
        <div
          ref={(node) => {
            el = node;
            capturedEl = node;
            Object.defineProperty(node, "offsetWidth", { value: size.width, configurable: true });
            vi.spyOn(node, "getBoundingClientRect").mockReturnValue({
              x: 0,
              y: 0,
              top: 0,
              left: 0,
              right: size.width,
              bottom: size.height,
              width: size.width,
              height: size.height,
              toJSON: () => ({}),
            });
          }}
          style={style()}
        />
      );
    });
    cleanups.push(unmount);
    return capturedEl;
  }

  it("uses margin = 8 and flips above cursor instead of clamping into the middle when near bottom", () => {
    Object.defineProperty(window, "innerWidth", { value: 1024, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: 600, configurable: true });

    // Near bottom: y = 520, menu height = 180 -> 520 + 180 = 700 > 592, and 520 - 180 = 340 >= 8.
    const flipped = mountPointOverlay({ x: 40, y: 520 }, { width: 220, height: 180 });
    expect(flipped.style.left).toBe("40px");
    expect(flipped.style.top).toBe("340px");

    // Near top-left edge: uses margin = 8 (not 16).
    const edge = mountPointOverlay({ x: 2, y: 3 }, { width: 220, height: 180 });
    expect(edge.style.left).toBe("8px");
    expect(edge.style.top).toBe("8px");
  });
});
