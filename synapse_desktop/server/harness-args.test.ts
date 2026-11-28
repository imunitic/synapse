import { describe, expect, it } from 'vitest'
import { modelArgs } from './harness-args.ts'

describe('modelArgs', () => {
  it('gives Claude --model and --effort', () => {
    expect(modelArgs('Claude', 'opus', 'high')).toEqual(['--model', 'opus', '--effort', 'high'])
    expect(modelArgs('Claude', undefined, 'high')).toEqual(['--effort', 'high'])
    expect(modelArgs('Claude')).toEqual([])
  })

  it('gives Codex -m and model_reasoning_effort', () => {
    expect(modelArgs('Codex', 'gpt-x', 'xhigh')).toEqual([
      '-m',
      'gpt-x',
      '-c',
      'model_reasoning_effort="xhigh"',
    ])
    expect(modelArgs('Codex', undefined, 'xhigh')).toEqual(['-c', 'model_reasoning_effort="xhigh"'])
    expect(modelArgs('Codex')).toEqual([])
  })

  it('gives OpenCode the variant as part of the model', () => {
    expect(modelArgs('Opencode', 'prov/model', 'high')).toEqual(['-m', 'prov/model#high'])
    expect(modelArgs('Opencode', 'prov/model')).toEqual(['-m', 'prov/model'])
    expect(modelArgs('Opencode')).toEqual([])
  })

  it('gives OpenCode nothing for a variant without a model', () => {
    expect(modelArgs('Opencode', undefined, 'high')).toEqual([])
  })
})
