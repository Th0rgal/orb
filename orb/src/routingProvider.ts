export interface RoutingProvider { id: string; name: string; models: { id: string; name: string }[] }
export function routingProvider(catalog: RoutingProvider[], id: string): RoutingProvider | undefined {
  return catalog.find(p => p.id === id) ?? catalog.find(p => p.id.startsWith("custom:") &&
    (p.id.slice(7) === id || p.name.toLowerCase().replace(/[^a-z0-9]/g, "") === id));
}
export function routingProviderLabel(catalog: RoutingProvider[], id: string): string {
  return routingProvider(catalog, id)?.name || id;
}
