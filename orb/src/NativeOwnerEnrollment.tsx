import { For, Show, Suspense, createResource, createSignal } from "solid-js";
import { api, connectionVersion } from "./api";
import { nativeLaunchWarning } from "./missionLaunch";
import { SettingsRow } from "./SettingsCard";

const path = "/api/native-owner-enrollments";
type Enrollment = { account_id: string; revision: number; launch_block?: string };

function OwnerNode(p: { node: string; account: string }) {
  const uri = () => path + "/" + encodeURIComponent(p.node);
  const [record, { refetch }] = createResource(() => [connectionVersion(), p.node] as const,
    () => api<Enrollment>(uri()));
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const bound = () => record()?.account_id === p.account;
  async function save() {
    const current = record();
    if (!current || busy()) return;
    setBusy(true);
    setError("");
    try {
      await api(uri(), { method: "PUT", body: JSON.stringify({
        expected_revision: current.revision, account_id: bound() ? "" : p.account
      }) });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      await refetch();
      setBusy(false);
    }
  }
  return <Suspense fallback={null}>
    <SettingsRow title={p.node} desc={
      <Show when={record()}>{r => <>
        <span>{bound() ? "This account is enrolled." : r().account_id ? "Another account is enrolled." : "No enrolled account."}</span>
        <Show when={bound() && nativeLaunchWarning(r().launch_block)}>{reason => <> · <span role="status">{reason()}</span></>}</Show>
      </>}</Show>
    }>
      <Show when={record()}>{r =>
        <button class="s-btn" disabled={busy()} onClick={() => void save()}>
          {bound() ? "Remove enrollment" : r().account_id ? "Replace enrolled account" : "Enroll this account"}
        </button>
      }</Show>
      <Show when={error() || record.error}><span role="alert">{error() || "Could not read enrollment."}</span></Show>
    </SettingsRow>
  </Suspense>;
}

export function NativeOwnerEnrollment(p: { account: string }) {
  const [nodes] = createResource(connectionVersion, () => api<string[]>(path));
  return <Suspense fallback={null}>
    <Show when={!nodes.error}><For each={nodes()}>{node =>
      <OwnerNode node={node} account={p.account} />
    }</For></Show>
  </Suspense>;
}
