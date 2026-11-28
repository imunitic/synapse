// Pure policy for mapping an already-authenticated gateway identity to one private
// Synapse host. The public browser never chooses a backend, route key or container.
//
// This module does not authenticate users or proxy requests; a gateway must
// validate a server-side session before calling it.
export interface GatewayPrincipal {
  readonly userId: string
}

export interface PrivateHost {
  readonly userId: string
  readonly backend: string
}

export class RouteDenied extends Error {
  constructor() {
    super('Synapse host route denied')
    this.name = 'RouteDenied'
  }
}

export function hostForPrincipal(
  principal: GatewayPrincipal | null,
  hosts: ReadonlyMap<string, PrivateHost>,
): PrivateHost {
  if (principal === null || principal.userId.length === 0) throw new RouteDenied()
  const host = hosts.get(principal.userId)
  if (host === undefined || host.userId !== principal.userId) throw new RouteDenied()
  return host
}
