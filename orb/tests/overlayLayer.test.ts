import { afterEach, describe, expect, it } from "vitest";
import { inertHoldDepth, mountOverlay, type OverlayLayer } from "../src/overlayLayer";

describe("overlayLayer stacked modal inert holds", () => {
  const mountedNodes: HTMLElement[] = [];
  afterEach(() => {
    for (const node of mountedNodes.splice(0)) node.remove();
    document.body.style.overflow = "";
  });

  it("ref-counts background and outer-modal inert holds across nested modal lifecycles", () => {
    const appRoot = document.createElement("div");
    const preInertSibling = document.createElement("aside");
    preInertSibling.setAttribute("inert", "");
    const outerPortal = document.createElement("div");
    const outerDialog = document.createElement("div");
    outerPortal.appendChild(outerDialog);
    const innerPortal = document.createElement("div");
    const innerDialog = document.createElement("div");
    innerPortal.appendChild(innerDialog);
    document.body.append(appRoot, preInertSibling, outerPortal, innerPortal);
    mountedNodes.push(appRoot, preInertSibling, outerPortal, innerPortal);

    const outerLayer: OverlayLayer = { root: () => outerDialog, modal: true };
    const innerLayer: OverlayLayer = { root: () => innerDialog, parent: outerLayer, modal: true };

    const unmountOuter = mountOverlay(outerLayer, { close: () => {}, trap: false });
    expect(appRoot.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(appRoot)).toBe(1);
    expect(preInertSibling.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(preInertSibling)).toBe(1);
    expect(outerPortal.hasAttribute("inert")).toBe(false);
    expect(outerDialog.hasAttribute("inert")).toBe(false);
    expect(document.body.style.overflow).toBe("hidden");

    const unmountInner = mountOverlay(innerLayer, { close: () => {}, trap: false });
    expect(appRoot.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(appRoot)).toBe(2);
    expect(inertHoldDepth(preInertSibling)).toBe(2);
    expect(outerPortal.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(outerPortal)).toBe(1);
    expect(innerPortal.hasAttribute("inert")).toBe(false);
    expect(innerDialog.hasAttribute("inert")).toBe(false);

    unmountInner();
    expect(appRoot.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(appRoot)).toBe(1);
    expect(preInertSibling.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(preInertSibling)).toBe(1);
    expect(outerPortal.hasAttribute("inert")).toBe(false);
    expect(inertHoldDepth(outerPortal)).toBe(0);
    expect(document.body.style.overflow).toBe("hidden");

    unmountOuter();
    expect(appRoot.hasAttribute("inert")).toBe(false);
    expect(inertHoldDepth(appRoot)).toBe(0);
    expect(preInertSibling.hasAttribute("inert")).toBe(true);
    expect(inertHoldDepth(preInertSibling)).toBe(0);
    expect(document.body.style.overflow).toBe("");
  });
});
