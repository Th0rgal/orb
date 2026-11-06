import { lazy } from "solid-js";

type CloudAgentsModule = typeof import("./CloudAgents");

let cachedModule: CloudAgentsModule | undefined;
let inflight: Promise<CloudAgentsModule> | undefined;

export function loadCloudAgentsModule(): Promise<CloudAgentsModule> {
  if (cachedModule) return Promise.resolve(cachedModule);
  inflight ??= import("./CloudAgents")
    .then((mod) => {
      cachedModule = mod;
      return mod;
    })
    .catch((err) => {
      inflight = undefined;
      throw err;
    });
  return inflight;
}

export function peekCloudAgentsModule(): CloudAgentsModule | undefined {
  return cachedModule;
}

export const LazyCloudAgentPage = lazy(() =>
  loadCloudAgentsModule().then((mod) => ({ default: mod.CloudAgentPage })),
);

export const LazyCloudConversation = lazy(() =>
  loadCloudAgentsModule().then((mod) => ({ default: mod.CloudConversation })),
);
