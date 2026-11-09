export const NAMESPACE_KEY = 'synapse-desktop.graph-namespace'

export function remembered(): string | null {
  try {
    return localStorage.getItem(NAMESPACE_KEY)
  } catch {
    return null
  }
}

export function remember(namespace: string): void {
  try {
    localStorage.setItem(NAMESPACE_KEY, namespace)
  } catch {
    // The choice is only a convenience.
  }
}
