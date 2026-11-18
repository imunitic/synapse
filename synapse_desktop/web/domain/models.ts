// Finding a model among the many a harness lists, and what a name of one has to look like.

import { MODEL_NAME } from '../../shared/models.ts'
import type { ModelOption } from '../../shared/transport.ts'

export function isModelName(text: string): boolean {
  return MODEL_NAME.test(text)
}

// The models that hold every word of `query`, in any case. What can be used comes first, as the
// list has it; among those, a model whose own name, after its provider's, has the words comes
// before one that has them only in the provider's name, and a shorter name before a longer.
export function filterModels(
  models: readonly ModelOption[],
  query: string,
  limit: number,
): { shown: ModelOption[]; total: number } {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const matching = models.filter((m) => words.every((w) => m.id.toLowerCase().includes(w)))
  const ownName = (m: ModelOption) => m.id.slice(m.id.indexOf('/') + 1).toLowerCase()
  const inOwnName = (m: ModelOption) => (words.every((w) => ownName(m).includes(w)) ? 0 : 1)
  const ranked =
    words.length === 0
      ? matching
      : [...matching].sort(
          (a, b) =>
            Number(b.available) - Number(a.available) ||
            inOwnName(a) - inOwnName(b) ||
            a.id.length - b.id.length ||
            (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
        )
  return { shown: ranked.slice(0, limit), total: matching.length }
}
