import { afterEach, describe, expect, it } from "vitest";
import { applyAuthMeResponse, resetCurrentUserState } from "../src/accountAdmin";
import { ApiError, type AIProvider } from "../src/api";
import { canManageProvider, providerWriteError } from "../src/providerPermissions";

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

  it("never surfaces raw 403 JSON", () => {
    for (const code of ["not_account_owner", "base_url_not_allowed", "admin_required"]) {
      const msg = providerWriteError(new ApiError(403, JSON.stringify({ error: code })), "fallback");
      expect(msg).not.toContain("{");
      expect(msg).not.toContain("403");
    }
    expect(providerWriteError(new ApiError(500, "boom"), "fallback")).toBe("fallback");
    expect(providerWriteError(new Error("x"), "fallback")).toBe("fallback");
  });
});
