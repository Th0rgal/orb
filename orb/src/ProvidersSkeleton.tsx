export function ProvidersLoadingCard() {
  return (
    <div class="s-card p-skeleton-card" role="status" aria-label="Loading inference accounts">
      <div class="s-row p-skeleton-row"><span class="sk-bar p-sk-logo" /><div class="p-sk-lines"><span class="sk-bar p-sk-title" /><span class="sk-bar p-sk-sub" /></div></div>
      <div class="s-row p-skeleton-row"><span class="sk-bar p-sk-logo" /><div class="p-sk-lines"><span class="sk-bar p-sk-title" /><span class="sk-bar p-sk-sub" /></div></div>
      <div class="s-row p-skeleton-row"><span class="sk-bar p-sk-logo" /><div class="p-sk-lines"><span class="sk-bar p-sk-title" /><span class="sk-bar p-sk-sub" /></div></div>
    </div>
  );
}

export function ProvidersPageSkeleton() {
  return (
    <div class="page">
      <div class="page-head"><h2>Inference</h2></div>
      <ProvidersLoadingCard />
    </div>
  );
}
