// Narrowing a list by what is typed in its filter box.

// Whether a name holds every word of the query, in any case; an empty query
// holds everything.
export function matchesQuery(name: string, query: string): boolean {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const lower = name.toLowerCase()
  return words.every((word) => lower.includes(word))
}

export function filterByName<T extends { name: string }>(items: readonly T[], query: string): T[] {
  return items.filter((item) => matchesQuery(item.name, query))
}
