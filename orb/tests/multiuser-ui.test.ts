import { afterEach, describe, expect, it } from "vitest";
import {
  applyAuthMeResponse,
  currentUser,
  defaultUnixUsernameFor,
  isAdminUser,
  resetCurrentUserState,
  validUnixUsername,
} from "../src/accountAdmin";
import { isMissionParticipant } from "../src/api";
import { isAdminOnlyNode } from "../src/machines/nodes";
import { isProviderEnabled, isProviderUsable, providerStatusLine } from "../src/managedMachineModel";
import { formatUsdFromCents, parseUsdToCents } from "../src/missionSharesApi";
import { TranscriptReducer } from "../src/transcriptModel";

describe("multi-user RBAC, confinement, and sharing models", () => {
  afterEach(() => {
    resetCurrentUserState();
  });

  it("validates strict POSIX unix_username rules and derives orb-<slug>", () => {
    expect(validUnixUsername("orb-alice")).toBe(true);
    expect(validUnixUsername("alice_01")).toBe(true);
    expect(validUnixUsername("")).toBe(false);
    expect(validUnixUsername("Root")).toBe(false);
    expect(validUnixUsername("root")).toBe(false);
    expect(validUnixUsername("orb-node")).toBe(false);
    expect(validUnixUsername("orb-privd")).toBe(false);
    expect(validUnixUsername("admin")).toBe(false);
    expect(validUnixUsername("-leading-dash")).toBe(false);
    expect(validUnixUsername("a".repeat(32))).toBe(false);

    expect(defaultUnixUsernameFor("Alice")).toBe("orb-alice");
    expect(defaultUnixUsernameFor("  Bob.Smith@Example  ")).toBe("orb-bob-smith-example");
    expect(defaultUnixUsernameFor("...")).toBe("");
  });

  it("enforces fail-closed isAdminUser() across single_tenant and multi_user modes", () => {
    resetCurrentUserState("single_tenant");
    expect(isAdminUser()).toBe(true);

    // Multi-user fails closed before /api/auth/me resolves a principal
    resetCurrentUserState("multi_user");
    expect(isAdminUser()).toBe(false);

    applyAuthMeResponse({
      auth_mode: "multi_user",
      user: {
        id: "u-member",
        username: "alice",
        role: "member",
        unix_username: "orb-alice",
        daily_spend_cap_cents: 2500,
        spent_today_cents: 420,
      },
      capabilities: {
        can_manage_users: false,
        can_use_core_target: false,
        can_manage_global_providers: false,
      },
    });
    expect(isAdminUser()).toBe(false);
    expect(currentUser()?.username).toBe("alice");
    expect(currentUser()?.unix_username).toBe("orb-alice");
    expect(currentUser()?.daily_spend_cap_cents).toBe(2500);

    applyAuthMeResponse({
      auth_mode: "multi_user",
      user: {
        id: "u-admin",
        username: "thomas",
        role: "admin",
        unix_username: null,
        daily_spend_cap_cents: null,
        spent_today_cents: 0,
      },
      capabilities: {
        can_manage_users: true,
        can_use_core_target: true,
        can_manage_global_providers: true,
      },
    });
    expect(isAdminUser()).toBe(true);
    expect(currentUser()?.role).toBe("admin");
  });

  it("identifies participant vs owner viewer_role on shared missions", () => {
    expect(isMissionParticipant(null)).toBe(false);
    expect(isMissionParticipant({ viewer_role: "owner" })).toBe(false);
    expect(isMissionParticipant({ viewer_role: undefined })).toBe(false);
    expect(isMissionParticipant({ viewer_role: "participant" })).toBe(true);
  });

  it("marks Core, co-located, and admin-only nodes as admin-restricted", () => {
    expect(isAdminOnlyNode({ id: "core" })).toBe(true);
    expect(isAdminOnlyNode({ id: "agent-core" })).toBe(true);
    expect(isAdminOnlyNode({ id: "dgx-spark-admin" })).toBe(true);
    expect(isAdminOnlyNode({ id: "leaf-1", admin_only: true })).toBe(true);
    expect(isAdminOnlyNode({ id: "leaf-2", core_colocated: true })).toBe(true);
    expect(isAdminOnlyNode({ id: "leaf-3", labels: ["gpu", "admin-only"] })).toBe(true);
    expect(isAdminOnlyNode({ id: "ashur", admin_only: false, core_colocated: false, labels: ["lean"] })).toBe(false);
  });

  it("computes effective managed-provider state across global and per-user preferences", () => {
    const base = { configured: true, globally_enabled: true, user_enabled: true, effective_enabled: true };
    expect(isProviderEnabled(base)).toBe(true);
    expect(isProviderUsable(base)).toBe(true);

    const userMuted = { ...base, user_enabled: false, effective_enabled: false };
    expect(isProviderEnabled(userMuted)).toBe(false);
    expect(isProviderUsable(userMuted)).toBe(false);
    expect(providerStatusLine(userMuted)).toBe("Skipped for your missions");

    const adminMuted = { ...base, globally_enabled: false, user_enabled: true, effective_enabled: false };
    expect(isProviderEnabled(adminMuted)).toBe(false);
    expect(providerStatusLine(adminMuted)).toBe("Disabled by admin");
  });

  it("parses and formats daily USD spend caps in cents", () => {
    expect(formatUsdFromCents(0)).toBe("$0.00");
    expect(formatUsdFromCents(2550)).toBe("$25.50");
    expect(parseUsdToCents("")).toBeNull();
    expect(parseUsdToCents("  ")).toBeNull();
    expect(parseUsdToCents("$15")).toBe(1500);
    expect(parseUsdToCents("12.34")).toBe(1234);
    expect(parseUsdToCents("-5")).toBeUndefined();
    expect(parseUsdToCents("abc")).toBeUndefined();
  });

  it("preserves sender_username attribution across user_message transcript events", () => {
    const reducer = new TranscriptReducer();
    reducer.apply({
      type: "user_message",
      event_id: "evt-1",
      sequence: 1,
      data: {
        id: "msg-1",
        content: "Can you check the proof?",
        sender_username: "alice",
      },
    });
    reducer.apply({
      type: "user_message",
      event_id: "evt-2",
      sequence: 2,
      data: {
        id: "msg-2",
        content: "Running turbo-lean now.",
        sender_username: "bob",
      },
    });
    const users = reducer.items.filter((i) => i.kind === "user");
    expect(users).toHaveLength(2);
    expect(users[0]?.kind === "user" ? users[0].senderUsername : undefined).toBe("alice");
    expect(users[1]?.kind === "user" ? users[1].senderUsername : undefined).toBe("bob");
  });
});
