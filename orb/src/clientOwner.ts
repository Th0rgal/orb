import type { Mission } from "./api";

/** `placement:client` no longer implies "this desktop": an iPhone can own a
 * client mission too. Core stamps `worker-client:<id>` and
 * `client-platform:<platform>` on missions created for a registered client. */
export const CLIENT_TAG = "placement:client";
export const isClientPlaced = (mission?: Pick<Mission, "tags"> | null) => !!mission?.tags?.includes(CLIENT_TAG);
export const clientOwner = (mission?: Pick<Mission, "tags"> | null) =>
  mission?.tags?.find(tag => tag.startsWith("worker-client:"))?.slice("worker-client:".length);
export const clientPlatform = (mission?: Pick<Mission, "tags"> | null) =>
  mission?.tags?.find(tag => tag.startsWith("client-platform:"))?.slice("client-platform:".length);

const PLATFORM_LABELS: Record<string, string> = { ios: "iPhone", ipados: "iPad", android: "Android device" };

/** Missions owned by a phone run there; the desktop must neither run nor
 * resume them, even though they are client-placed. */
export const ownedByMobileClient = (mission?: Pick<Mission, "tags"> | null) => {
  const platform = clientPlatform(mission);
  return !!platform && platform in PLATFORM_LABELS;
};

/** Label for the machine that runs a client-placed mission. */
export function clientMachineLabel(mission?: Pick<Mission, "tags"> | null, localClientId?: string) {
  const platform = clientPlatform(mission);
  if (platform && platform in PLATFORM_LABELS) return PLATFORM_LABELS[platform];
  const owner = clientOwner(mission);
  if (owner && localClientId && owner !== localClientId) return "Another computer";
  return "This computer";
}
