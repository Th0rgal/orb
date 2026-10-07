import { expect, it } from "vitest";
import { clientMachineLabel, ownedByMobileClient } from "../src/clientOwner";

it("labels client missions by their owning platform instead of assuming this computer", () => {
  expect(clientMachineLabel({ tags: ["placement:client", "worker-client:p", "client-platform:ios"] })).toBe("iPhone");
  expect(clientMachineLabel({ tags: ["placement:client"] })).toBe("This computer");
  expect(clientMachineLabel({ tags: ["placement:client", "worker-client:other"] }, "me")).toBe("Another computer");
  expect(ownedByMobileClient({ tags: ["placement:client", "client-platform:ios"] })).toBe(true);
  expect(ownedByMobileClient({ tags: ["placement:client", "client-platform:macos"] })).toBe(false);
});
