import { afterEach, describe, expect, it } from "vitest";
import { applyAuthMeResponse, resetCurrentUserState } from "../src/accountAdmin";
import { ApiError, type AIProvider } from "../src/api";
import { canManageProvider, isCustomBaseUrlAllowed, isMemberCustomBaseUrlAllowed, providerWriteError } from "../src/providerPermissions";

const acct = (extra: Partial<AIProvider> = {}): AIProvider => ({
  id: "p1", provider_type: "openai", provider_type_name: "OpenAI", name: "OpenAI", enabled: true,
  uses_oauth: false, status: { type: "connected" }, ...extra,
});

function signIn(role: "admin" | "member") {
  applyAuthMeResponse({
    auth_mode: "multi_user",
    user: { id: `u-${role}`, username: role, role, unix_username: null, daily_spend_cap_cents: null, spent_today_cents: 0 },
    capabilities: { can_manage_users: role === "admin", can_use_core_target: role === "admin", can_manage_global_providers: role === "admin" },
  });
}

describe("shared provider permissions (docs/MULTI_USER.md §5)", () => {
  afterEach(() => resetCurrentUserState());

  it("member manages only accounts they added; admin manages all", () => {
    resetCurrentUserState("multi_user");
    signIn("member");
    expect(canManageProvider(acct())).toBe(false);
    expect(canManageProvider(acct({ added_by_me: true }))).toBe(true);
    signIn("admin");
    expect(canManageProvider(acct())).toBe(true);
  });

  it("validates member custom base URLs against private/internal/non-https hosts", () => {
    expect(isMemberCustomBaseUrlAllowed("https://api.example.com/v1")).toBe(true);
    expect(isMemberCustomBaseUrlAllowed("https://100.example.com/v1")).toBe(true);
    expect(isMemberCustomBaseUrlAllowed("https://172.32.0.1/v1")).toBe(true);
    expect(isMemberCustomBaseUrlAllowed("http://api.example.com/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://localhost:8000/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://sub.localhost/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://svc.internal/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://printer.local/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://127.0.0.1:8080/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://10.0.0.1/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://192.168.1.1/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://169.254.169.254/latest")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://172.16.0.1/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://172.31.255.1/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://100.64.0.1/v1")).toBe(false);
    expect(isMemberCustomBaseUrlAllowed("https://[::1]:8080/v1")).toBe(false);
    expect(isCustomBaseUrlAllowed("http://localhost:11434/v1", true)).toBe(true);
    expect(isCustomBaseUrlAllowed("http://localhost:11434/v1", false)).toBe(false);
  });

  it("never surfaces raw 403 JSON", () => {
    for (const code of ["not_account_owner", "base_url_not_allowed", "admin_required", "account_disabled"]) {
      const msg = providerWriteError(new ApiError(403, JSON.stringify({ error: code })), "fallback");
      expect(msg).not.toContain("{");
      expect(msg).not.toContain("403");
    }
    expect(providerWriteError(new ApiError(500, "boom"), "fallback")).toBe("fallback");
    expect(providerWriteError(new Error("x"), "fallback")).toBe("fallback");
  });
});
