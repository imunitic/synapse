import { describe, expect, it } from 'vitest'
import { graphFont } from './measure-text.ts'

describe('graphFont', () => {
  it('draws a step name bold at 0.875rem', () => {
    expect(graphFont('name', 16, 'Inter')).toBe('600 14px Inter')
  })

  it('draws the line below a name at 0.75rem', () => {
    expect(graphFont('sub', 18, 'Inter')).toBe('13.5px Inter')
  })
})
