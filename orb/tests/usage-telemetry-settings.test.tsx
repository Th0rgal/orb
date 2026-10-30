import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { UsageTelemetryConfig, UsageTelemetryStatus } from "../src/usageTelemetry";

let currentStatus: UsageTelemetryStatus = {
  enabled: true,
  prompts_enabled: false,
  active: false,
  hub_url: "https://telemetry.thomas.md",
  namespace: null,
  token_configured: false,
  queued: 0,
  last_error: null,
};

const updates: UsageTelemetryConfig[] = [];

vi.mock("../src/usageTelemetry", async () => {
  const actual = await vi.importActual<typeof import("../src/usageTelemetry")>("../src/usageTelemetry");
  return {
    ...actual,
    getUsageTelemetryStatus: vi.fn(async () => ({ ...currentStatus })),
    updateUsageTelemetryConfig: vi.fn(async (patch: UsageTelemetryConfig) => {
      updates.push(patch);
      const ns = patch.namespace !== undefined ? (patch.namespace || null) : currentStatus.namespace;
      const tokenConfigured =
        patch.token !== undefined ? patch.token.length > 0 : currentStatus.token_configured;
      const enabled = patch.enabled ?? currentStatus.enabled;
      const promptsEnabled = enabled ? (patch.prompts_enabled ?? currentStatus.prompts_enabled) : false;
      currentStatus = {
        ...currentStatus,
        enabled,
        prompts_enabled: promptsEnabled,
        hub_url: patch.hub_url ?? currentStatus.hub_url,
        namespace: ns,
        token_configured: tokenConfigured,
        active: Boolean(enabled && ns && tokenConfigured),
      };
      return { ...currentStatus };
    }),
  };
});

import {
  UsageTelemetrySettings,
  telemetryNamespaceError,
} from "../src/UsageTelemetrySettings";

afterEach(() => {
  cleanup();
  updates.length = 0;
  currentStatus = {
    enabled: true,
    prompts_enabled: false,
    active: false,
    hub_url: "https://telemetry.thomas.md",
    namespace: null,
    token_configured: false,
    queued: 0,
    last_error: null,
  };
});

describe("UsageTelemetrySettings", () => {
  it("rejects uppercase, unsupported characters, overlong values, and community", () => {
    expect(telemetryNamespaceError("")).toBe("");
    expect(telemetryNamespaceError("th0rgal")).toBe("");
    expect(telemetryNamespaceError("my-ns_01")).toBe("");
    expect(telemetryNamespaceError("Th0rgal")).toContain("Uppercase letters aren’t allowed");
    expect(telemetryNamespaceError("th0rgal ")).toContain("Only lowercase letters");
    expect(telemetryNamespaceError("bad@char")).toContain("Only lowercase letters");
    expect(telemetryNamespaceError("a/b")).toContain("Only lowercase letters");
    expect(telemetryNamespaceError("a".repeat(41))).toContain("40 characters");
    expect(telemetryNamespaceError("community")).toContain("never community");
    expect(telemetryNamespaceError("Community")).toContain("never community");
  });

  it("uses shared SettingsRow layout, blocks invalid namespaces, and saves valid lowercase namespaces", async () => {
    const { container } = render(() => <UsageTelemetrySettings />);
    const nsInput = (await screen.findByLabelText("Telemetry namespace")) as HTMLInputElement;
    const urlInput = screen.getByLabelText("Telemetry hub URL") as HTMLInputElement;
    const tokenInput = screen.getByLabelText("Telemetry token") as HTMLInputElement;
    const saveBtn = screen.getByRole("button", { name: "Save" }) as HTMLButtonElement;

    // Every settings row uses .s-row-text so controls align in a clean right-hand column.
    const rows = Array.from(container.querySelectorAll(".s-row"));
    expect(rows.length).toBeGreaterThanOrEqual(7);
    for (const row of rows) {
      expect(row.querySelector(":scope > .s-row-text")).not.toBeNull();
    }

    expect(nsInput.getAttribute("autocapitalize")).toBe("off");
    expect(urlInput.getAttribute("autocapitalize")).toBe("off");
    expect(tokenInput.getAttribute("autocapitalize")).toBe("off");

    // Save stays disabled until the user changes a hub field.
    expect(saveBtn.disabled).toBe(true);

    // Reject "community", uppercase, and unsupported characters inline (and block Enter submit).
    await fireEvent.input(tokenInput, { target: { value: "tl_live_example_token" } });

    await fireEvent.input(nsInput, { target: { value: "community" } });
    expect(saveBtn.disabled).toBe(true);
    expect(nsInput.getAttribute("aria-invalid")).toBe("true");
    expect(screen.getByText(/never community/i)).toBeTruthy();

    await fireEvent.input(nsInput, { target: { value: "Th0rgal" } });
    expect(saveBtn.disabled).toBe(true);
    expect(nsInput.getAttribute("aria-invalid")).toBe("true");
    expect(screen.getByText(/Uppercase letters aren’t allowed/i)).toBeTruthy();
    await fireEvent.keyDown(nsInput, { key: "Enter" });
    expect(updates).toHaveLength(0);

    await fireEvent.input(nsInput, { target: { value: "th0rgal!" } });
    expect(saveBtn.disabled).toBe(true);
    expect(nsInput.getAttribute("aria-invalid")).toBe("true");
    expect(screen.getByText(/Only lowercase letters/i)).toBeTruthy();

    // Valid lowercase namespace enables Save and preserves draft across toggle updates.
    await fireEvent.input(nsInput, { target: { value: "th0rgal" } });
    expect(nsInput.getAttribute("aria-invalid")).toBeNull();
    expect(saveBtn.disabled).toBe(false);

    const promptsToggle = screen.getByRole("switch", { name: "Include prompts" });
    await fireEvent.click(promptsToggle);
    await waitFor(() => expect(updates).toContainEqual({ prompts_enabled: true }));
    expect(nsInput.value).toBe("th0rgal");

    await fireEvent.click(saveBtn);
    await waitFor(() =>
      expect(updates).toContainEqual({
        namespace: "th0rgal",
        hub_url: "https://telemetry.thomas.md",
        token: "tl_live_example_token",
      }),
    );

    await waitFor(() => expect(screen.getByRole("status").textContent).toContain("Sending · 0 queued"));
    expect((screen.getByRole("button", { name: "Save" }) as HTMLButtonElement).disabled).toBe(true);

    // Clear token is offered once configured.
    const clearBtn = screen.getByRole("button", { name: "Clear token" });
    await fireEvent.click(clearBtn);
    await waitFor(() => expect(updates).toContainEqual({ token: "" }));
  });
});

describe("Orb focus & selection CSS contract", () => {
  it("keeps focus monochrome and never attaches blue/purple or 2px rings to inputs or controls", () => {
    const srcDir = join(dirname(fileURLToPath(import.meta.url)), "..", "src");
    const collectCss = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...collectCss(full));
        else if (entry.name.endsWith(".css")) out.push(full);
      }
      return out;
    };
    const cssFiles = collectCss(srcDir);
    expect(cssFiles.length).toBeGreaterThanOrEqual(4);

    for (const file of cssFiles) {
      const css = readFileSync(file, "utf8");
      expect(css, file).not.toMatch(/--overlay-focus:\s*var\(--blue/);
      expect(css, file).not.toMatch(/outline:\s*2px\s+solid/);
      expect(css, file).not.toMatch(/outline:2px\s+solid/);
      expect(css, file).not.toMatch(/var\(--focus,\s*var\(--purple\)\)/);
      expect(css, file).not.toMatch(/\.s-input:focus-visible[^{]*\{[^}]*outline:\s*[1-9]/);
    }

    const rootCss = readFileSync(join(srcDir, "styles.css"), "utf8");
    expect(rootCss).toContain("--selection-bg:");
    expect(rootCss).toContain("::selection");
  });
});
