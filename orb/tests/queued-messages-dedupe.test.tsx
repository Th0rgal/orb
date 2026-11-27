import { describe, expect, it } from "vitest";
import { render, screen } from "@solidjs/testing-library";
import { QueuedMessages } from "../src/QueuedMessages";

describe("QueuedMessages transcript deduplication", () => {
  it("hides pending optimistic rows whose id or text is already visible in the active transcript turn", () => {
    const view = render(() => (
      <QueuedMessages
        mission="local-m1"
        delivered={["msg-delivered-1"]}
        deliveredTexts={["regarde ce que fait mon agent"]}
        pending={[
          { id: "msg-delivered-1", text: "other text matched by id" },
          { id: "draft-different-id", text: "  regarde ce que fait mon agent  " },
        ]}
      />
    ));
    expect(view.container.querySelector(".followup-queue")).toBeNull();
    expect(screen.queryByText(/Sending/)).toBeNull();
  });

  it("keeps genuinely queued pending follow-ups that are not yet in the transcript", () => {
    const view = render(() => (
      <QueuedMessages
        mission="local-m2"
        delivered={["msg-turn-1"]}
        deliveredTexts={["regarde ce que fait mon agent"]}
        pending={[
          { id: "draft-turn-1", text: "regarde ce que fait mon agent" },
          { id: "draft-next", text: "et ajoute aussi un test" },
        ]}
      />
    ));
    expect(view.container.querySelector(".followup-queue")).not.toBeNull();
    expect(screen.queryByText("regarde ce que fait mon agent")).toBeNull();
    expect(screen.getByText("et ajoute aussi un test")).toBeDefined();
  });
});
