import type { PrivilegeSnapshot } from "../src/privilegeAccessApi";

/** Full API response: unrelated endpoints must not invent a fleet lockdown. */
export const privilegeSnapshot = (bunker_state = 0): PrivilegeSnapshot => ({
  bunker_state, requests: [], audit: [], command_audit: [], bunker_incidents: [],
});
