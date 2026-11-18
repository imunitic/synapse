import { describe, expect, it } from 'vitest'
import type { ModelOption } from '../../shared/transport.ts'
import { filterModels, isModelName } from './models.ts'

const option = (id: string, available = true): ModelOption => ({
  id,
  provider: id.split('/')[0] ?? null,
  available,
  detail: null,
})

const MODELS = [
  option('opencode/glm-5.3-flash-free'),
  option('openrouter/z-ai/glm-5.3-flash'),
  option('openrouter/z-ai/glm-5.3'),
  option('anthropic/glm-lookalike', false),
  option('openrouter/deepseek/deepseek-v4'),
]

describe('finding a model', () => {
  it('holds every word, in any case', () => {
    expect(filterModels(MODELS, 'GLM flash', 10).shown.map((m) => m.id)).toEqual([
      'opencode/glm-5.3-flash-free',
      'openrouter/z-ai/glm-5.3-flash',
    ])
  })

  it('has a model that can be used before one that cannot, then the shorter name', () => {
    expect(filterModels(MODELS, 'glm', 10).shown.map((m) => m.id)).toEqual([
      'openrouter/z-ai/glm-5.3',
      'opencode/glm-5.3-flash-free',
      'openrouter/z-ai/glm-5.3-flash',
      'anthropic/glm-lookalike',
    ])
  })

  it('puts a match in the name of the model before one in the name of the provider', () => {
    const found = filterModels([option('deepseek/other'), option('x/deepseek-v4')], 'deepseek', 10)
    expect(found.shown.map((m) => m.id)).toEqual(['x/deepseek-v4', 'deepseek/other'])
  })

  it('shows no more than the limit, and says how many there are', () => {
    const found = filterModels(MODELS, 'z-ai', 1)
    expect(found.shown).toHaveLength(1)
    expect(found.total).toBe(2)
  })

  it('is the whole list, in its own order, for no words', () => {
    expect(filterModels(MODELS, '  ', 3).shown.map((m) => m.id)).toEqual(
      MODELS.slice(0, 3).map((m) => m.id),
    )
    expect(filterModels(MODELS, '', 10).total).toBe(5)
  })

  it('is nothing when no model has the words', () => {
    expect(filterModels(MODELS, 'nothing here', 10)).toEqual({ shown: [], total: 0 })
  })
})

describe('the name of a model', () => {
  it('is what the names of models are made of, and cannot be taken for a flag', () => {
    expect(isModelName('openrouter/~z-ai/glm-flash-latest')).toBe(true)
    expect(isModelName('sonnet')).toBe(true)
    expect(isModelName('--model')).toBe(false)
    expect(isModelName('a b')).toBe(false)
    expect(isModelName('')).toBe(false)
  })
})
