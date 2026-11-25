import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fireEvent, render, screen, within } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection } from "../src/api";
import {
  MOZHENZHEN_PROVIDER_COPY,
  MOZHENZHEN_PROVIDER_URL,
  PROVIDER_DIRECTORY_HINTS_DEFAULT,
  PROVIDER_DIRECTORY_HINTS_KEY,
  PROVIDER_DIRECTORY_SETTING_DESC,
  PROVIDER_DIRECTORY_SETTING_TITLE,
  setShowProviderDirectoryHints,
  showProviderDirectoryHints,
} from "../src/providerDirectoryHint";
import { Providers } from "../src/Providers";
import { Settings } from "../src/Settings";
import { notifyExternalStorageChange, resetStorageCache } from "../src/storage";

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "..",
      "..",
      "shared",
      "orb-spec",
      "fixtures",
      "provider-directory-hint.json",
    ),
    "utf8",
  ),
);

describe("providerDirectoryHint shared spec & UI", () => {
  beforeEach(() => {
    localStorage.clear();
    resetStorageCache();
    notifyExternalStorageChange(PROVIDER_DIRECTORY_HINTS_KEY);
  });

  afterEach(() => {
    clearConnection();
    localStorage.clear();
    resetStorageCache();
    notifyExternalStorageChange(PROVIDER_DIRECTORY_HINTS_KEY);
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("matches shared/orb-spec/fixtures/provider-directory-hint.json", () => {
    expect(PROVIDER_DIRECTORY_HINTS_KEY).toBe(fixture.storage_key);
    expect(PROVIDER_DIRECTORY_HINTS_DEFAULT).toBe(fixture.default_enabled);
    expect(MOZHENZHEN_PROVIDER_URL).toBe(fixture.url);
    expect(MOZHENZHEN_PROVIDER_COPY).toBe(fixture.copy);
    expect(PROVIDER_DIRECTORY_SETTING_TITLE).toBe(fixture.setting_title);
    expect(PROVIDER_DIRECTORY_SETTING_DESC).toBe(fixture.setting_description);
    expect(showProviderDirectoryHints()).toBe(true);
  });

  it("falls back to true on corrupt storage and persists false when disabled", () => {
    localStorage.setItem(PROVIDER_DIRECTORY_HINTS_KEY, "\"not-a-boolean\"");
    notifyExternalStorageChange(PROVIDER_DIRECTORY_HINTS_KEY);
    expect(showProviderDirectoryHints()).toBe(true);

    setShowProviderDirectoryHints(false);
    expect(showProviderDirectoryHints()).toBe(false);
    expect(localStorage.getItem(PROVIDER_DIRECTORY_HINTS_KEY)).toBe("false");
  });

  it("renders subtle Mozhenzhen link in Inference and Add API key dialog, opens URL, and hides when toggled off in Settings", async () => {
    setConnection("http://core.test", "test-token");
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.endsWith("/providers")) {
          return new Response(
            JSON.stringify([
              {
                id: "existing-key",
                provider_type: "openai",
                name: "Existing key",
                enabled: true,
                has_api_key: true,
                uses_oauth: false,
                status: { type: "connected" },
              },
            ]),
          );
        }
        return new Response(JSON.stringify({ entries: {} }));
      }),
    );

    render(() => (
      <>
        <Providers />
        <Settings />
      </>
    ));

    const pageLink = await screen.findByRole("link", {
      name: new RegExp(MOZHENZHEN_PROVIDER_COPY),
    });
    expect(pageLink.getAttribute("href")).toBe("https://mozhenzhen.com/go/orb");

    fireEvent.click(pageLink);
    expect(openSpy).toHaveBeenCalledWith("https://mozhenzhen.com/go/orb", "_blank");

    // Also appears subtly in Add API key dialog (new key setup), but not Edit API key.
    fireEvent.click(screen.getByRole("button", { name: "Add API key", exact: true }));
    const addDialog = await screen.findByRole("dialog");
    expect(
      within(addDialog)
        .getByRole("link", { name: new RegExp(MOZHENZHEN_PROVIDER_COPY) })
        .getAttribute("href"),
    ).toBe("https://mozhenzhen.com/go/orb");
    fireEvent.click(within(addDialog).getByRole("button", { name: "Cancel", exact: true }));

    fireEvent.click(screen.getByRole("button", { name: "Actions for Existing key", exact: true }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Edit API key", exact: true }));
    const editDialog = await screen.findByRole("dialog");
    expect(
      within(editDialog).queryByRole("link", { name: new RegExp(MOZHENZHEN_PROVIDER_COPY) }),
    ).toBeNull();
    fireEvent.click(within(editDialog).getByRole("button", { name: "Cancel", exact: true }));

    // Toggle off in Settings -> Appearance -> Provider directory link.
    const toggle = screen.getByRole("switch", { name: "Show provider directory link" });
    expect(toggle.getAttribute("aria-checked")).toBe("true");
    fireEvent.click(toggle);
    expect(toggle.getAttribute("aria-checked")).toBe("false");
    expect(screen.queryByRole("link", { name: new RegExp(MOZHENZHEN_PROVIDER_COPY) })).toBeNull();
  });
});
