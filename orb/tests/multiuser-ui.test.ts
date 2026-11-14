import { afterEach, describe, expect, it } from "vitest";
import {
  applyAuthMeResponse,
  buildSingleTenantAdminUser,
  currentUser,
  defaultUnixUsernameFor,
  isAdminUser,
  isLegacySingleTenantUsersFallback,
  resetCurrentUserState,
  validUnixUsername,
} from "../src/accountAdmin";
import { encodeWsJwtSubprotocol, isMissionParticipant, sanitizeWsErrorText } from "../src/api";
import { isAdminOnlyNode } from "../src/machines/nodes";
import {
  firstUsableAutoManagedTarget,
  isProviderEnabled,
  isProviderUsable,
  providerStatusLine,
  resolveDefaultComposerMachine,
  type ManagedCatalogState,
} from "../src/managedMachineModel";
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
    const base = { provider: "leanci", configured: true, globally_enabled: true, user_enabled: true, effective_enabled: true };
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

  it("requires personal opt-in for every non-Boat provider even with stale effective state", () => {
    for (const provider of ["leanci", "hetzner", "vastai", "scaleway", "colab", "future"]) {
      const p = { provider, configured: true, enabled: true, effective_enabled: true };
      expect(isProviderEnabled(p)).toBe(false);
      expect(isProviderUsable(p)).toBe(false);
      expect(providerStatusLine(p)).toBe("Skipped for your missions");
      expect(isProviderEnabled({ ...p, user_enabled: true })).toBe(true);
      expect(isProviderEnabled({ ...p, user_enabled: true, globally_enabled: false })).toBe(false);
    }
    expect(isProviderEnabled({ provider: "boat", enabled: true })).toBe(true);
    expect(isProviderEnabled({ provider: "boat", user_enabled: false, effective_enabled: true })).toBe(false);
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

  it("synthesizes @admin fallback only on 404 against non-multi_user servers", () => {
    expect(isLegacySingleTenantUsersFallback(404, "single_tenant")).toBe(true);
    expect(isLegacySingleTenantUsersFallback(404, "disabled")).toBe(true);
    expect(isLegacySingleTenantUsersFallback(404, null)).toBe(true);
    expect(isLegacySingleTenantUsersFallback(404, "multi_user")).toBe(false);
    expect(isLegacySingleTenantUsersFallback(500, "single_tenant")).toBe(false);

    resetCurrentUserState("single_tenant");
    const fallback = buildSingleTenantAdminUser();
    expect(fallback.id).toBe("admin");
    expect(fallback.username).toBe("admin");
    expect(fallback.role).toBe("admin");
    expect(fallback.disabled).toBe(false);
  });

  it("encodes orb-jwt-v2 colons to RFC 6455 tchar tildes and redacts leaked tokens in WebSocket errors", () => {
    const rawV2 = "orb-jwt-v2:u-alice:member:3:1893456000.deadbeefcafebabe";
    expect(encodeWsJwtSubprotocol(rawV2)).toBe(
      "jwt.orb-jwt-v2~u-alice~member~3~1893456000.deadbeefcafebabe",
    );
    expect(encodeWsJwtSubprotocol("eyJhbGciOiJIUzI1NiJ9.payload.sig")).toBe(
      "jwt.eyJhbGciOiJIUzI1NiJ9.payload.sig",
    );
    expect(encodeWsJwtSubprotocol("")).toBeNull();
    expect(encodeWsJwtSubprotocol(null)).toBeNull();

    const domException = new Error(
      `Failed to construct 'WebSocket': The subprotocol 'jwt.${rawV2}' is invalid.`,
    );
    const sanitized = sanitizeWsErrorText(domException);
    expect(sanitized).toBe(
      "Failed to construct 'WebSocket': The subprotocol 'jwt.<redacted>' is invalid.",
    );
    expect(sanitized).not.toContain("u-alice");
    expect(sanitized).not.toContain("deadbeefcafebabe");

    const bareLeak = sanitizeWsErrorText(
      `Handshake rejected token ${rawV2.replaceAll(":", "~")} on /api/monitoring/ws`,
    );
    expect(bareLeak).toBe("Handshake rejected token jwt.<redacted> on /api/monitoring/ws");
    expect(bareLeak).not.toContain("u-alice");
  });

  it("prefers the first usable auto-managed target over local for non-admins when no static fleet node is available", () => {
    const usableCatalog: ManagedCatalogState = {
      loaded: true,
      enabled: true,
      providers: [
        {
          provider: "boat",
          display_name: "boat.dev",
          configured: true,
          enabled: true,
          globally_enabled: true,
          user_enabled: true,
          effective_enabled: true,
          supports_snapshots: true,
          supports_free_stop: true,
          sizes: [
            { size: "small", cpu: 2, ram_gb: 4, disk_gb: 20, usd_per_hour: 0.018 },
            { size: "large", cpu: 8, ram_gb: 16, disk_gb: 80, usd_per_hour: 0.1 },
          ],
        },
      ],
      budget: {
        spent_today_usd: 0,
        daily_cap_usd: 25,
        active: 0,
        max_concurrent: 2,
        default_ttl_minutes: 60,
        max_ttl_minutes: 720,
        default_size: "small",
        max_size: "large",
      },
      settings: { antigravity_on_managed: true },
    };
    const emptyCatalog: ManagedCatalogState = {
      loaded: true,
      enabled: false,
      providers: [],
      budget: null,
      settings: null,
    };

    expect(firstUsableAutoManagedTarget(usableCatalog)).toBe("auto-managed:boat:small");
    expect(firstUsableAutoManagedTarget(emptyCatalog)).toBeNull();

    // Non-admin moving off forbidden "core" with no static node gets usable auto-managed VM
    expect(
      resolveDefaultComposerMachine({
        isAdmin: false,
        current: "core",
        explicit: false,
        firstNodeId: null,
        remoteReady: true,
        catalog: usableCatalog,
      }),
    ).toBe("auto-managed:boat:small");

    // Non-admin with no usable cloud providers falls back to "local"
    expect(
      resolveDefaultComposerMachine({
        isAdmin: false,
        current: "core",
        explicit: false,
        firstNodeId: null,
        remoteReady: true,
        catalog: emptyCatalog,
      }),
    ).toBe("local");

    // Existing auto-managed selection is not clobbered when remoteReady settles
    expect(
      resolveDefaultComposerMachine({
        isAdmin: false,
        current: "auto-managed:boat:large",
        explicit: false,
        firstNodeId: null,
        remoteReady: true,
        catalog: usableCatalog,
      }),
    ).toBe("auto-managed:boat:large");

    // Non-admin on "local" (before catalog arrived) upgrades to auto-managed once catalog loads
    expect(
      resolveDefaultComposerMachine({
        isAdmin: false,
        current: "local",
        explicit: false,
        firstNodeId: null,
        remoteReady: true,
        catalog: usableCatalog,
      }),
    ).toBe("auto-managed:boat:small");

    // Admin behavior remains identical ("core" when no static node is available)
    expect(
      resolveDefaultComposerMachine({
        isAdmin: true,
        current: "ashur",
        explicit: false,
        firstNodeId: null,
        remoteReady: true,
        catalog: usableCatalog,
      }),
    ).toBe("core");
  });
});
