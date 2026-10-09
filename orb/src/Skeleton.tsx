import { Show, createSignal, onCleanup, onMount } from "solid-js";

/** Fast history reads never flash placeholder content. New missions skip this. */
export function DelayedTranscriptSkeleton() {
  const [visible, setVisible] = createSignal(false);
  onMount(() => {
    const timer = setTimeout(() => setVisible(true), 300);
    onCleanup(() => clearTimeout(timer));
  });
  return <Show when={visible()}><TranscriptSkeleton /></Show>;
}

/** Placeholders that reuse live row metrics so the dock does not jump when
 * the real payload arrives. */
export function TranscriptSkeleton() {
  return (
    <div class="sk-transcript" aria-hidden="true">
      <div class="st-work-head sk-bar" style={{ width: "36%" }} />
      <div class="sk-lines">
        <i style={{ width: "92%" }} />
        <i style={{ width: "74%" }} />
        <i style={{ width: "88%" }} />
        <i style={{ width: "41%" }} />
      </div>
      <div class="user sk-user" />
      <div class="sk-lines">
        <i style={{ width: "86%" }} />
        <i style={{ width: "63%" }} />
        <i style={{ width: "79%" }} />
      </div>
    </div>
  );
}

export function FileSkeleton() {
  return (
    <div class="sk-transcript" aria-hidden="true">
      <div class="sk-lines">
        <i style={{ width: "28%", height: "18px" }} />
        <i style={{ width: "96%" }} />
        <i style={{ width: "90%" }} />
        <i style={{ width: "94%" }} />
        <i style={{ width: "62%" }} />
        <i style={{ width: "88%" }} />
        <i style={{ width: "70%" }} />
      </div>
    </div>
  );
}

export function ControllerSkeleton() {
  return (
    <div class="sk-transcript" aria-hidden="true">
      <div class="sk-bar" style={{ width: "48%", height: "28px", margin: "0 0 14px" }} />
      <div class="sk-bar" style={{ width: "100%", height: "56px", margin: "0 0 8px" }} />
      <div class="sk-bar" style={{ width: "100%", height: "56px", margin: "0 0 8px" }} />
      <div class="sk-bar" style={{ width: "100%", height: "56px" }} />
    </div>
  );
}

/** Same centered column as the conversation, before its mission is resolved. */
export function ConversationSkeleton() {
  return <div class="scroll" role="status" aria-label="Loading conversation" aria-busy="true">
    <div class="col">
      <div class="sk-transcript" aria-hidden="true">
        <div class="sk-lines">
          <i style={{ width: "58%" }} />
          <i style={{ width: "86%" }} />
          <i style={{ width: "72%" }} />
        </div>
      </div>
    </div>
  </div>;
}

/** Two-line placeholders matching the Inbox list geometry. */
export function InboxSkeleton() {
  return (
    <div class="inbox-skeleton" role="status" aria-label="Loading inbox" aria-busy="true">
      <div class="inbox-sk-sec" aria-hidden="true">
        <div class="sk-bar inbox-sk-head" style={{ width: "96px", height: "12px" }} />
        <div class="inbox-sk-list">
          <div class="inbox-sk-row">
            <div class="inbox-sk-top">
              <i class="inbox-sk-dot" />
              <i class="sk-bar" style={{ width: "74px", height: "13px" }} />
              <i class="sk-bar" style={{ width: "38%", height: "14px" }} />
              <i class="sk-bar inbox-sk-time" style={{ width: "28px", height: "12px" }} />
            </div>
            <i class="sk-bar inbox-sk-line" style={{ width: "82%", height: "13px" }} />
          </div>
          <div class="inbox-sk-row">
            <div class="inbox-sk-top">
              <i class="inbox-sk-dot" />
              <i class="sk-bar" style={{ width: "62px", height: "13px" }} />
              <i class="sk-bar" style={{ width: "46%", height: "14px" }} />
              <i class="sk-bar inbox-sk-time" style={{ width: "32px", height: "12px" }} />
            </div>
            <i class="sk-bar inbox-sk-line" style={{ width: "68%", height: "13px" }} />
          </div>
          <div class="inbox-sk-row">
            <div class="inbox-sk-top">
              <i class="inbox-sk-dot" />
              <i class="sk-bar" style={{ width: "88px", height: "13px" }} />
              <i class="sk-bar" style={{ width: "31%", height: "14px" }} />
              <i class="sk-bar inbox-sk-time" style={{ width: "26px", height: "12px" }} />
            </div>
            <i class="sk-bar inbox-sk-line" style={{ width: "75%", height: "13px" }} />
          </div>
        </div>
      </div>
    </div>
  );
}
