import { describe, expect, it } from 'vitest'
import { DEFAULT_THEME, parseTheme, resolveTheme } from './theme.ts'

describe('the theme', () => {
  it('is dark unless another choice was kept', () => {
    expect(DEFAULT_THEME).toBe('dark')
    expect(parseTheme(null)).toBe('dark')
    expect(parseTheme('light')).toBe('light')
    expect(parseTheme('system')).toBe('system')
    expect(parseTheme('dark')).toBe('dark')
    expect(parseTheme('purple')).toBe('dark')
    expect(parseTheme('')).toBe('dark')
  })

  it('follows the computer only when System is chosen', () => {
    expect(resolveTheme('system', true)).toBe('light')
    expect(resolveTheme('system', false)).toBe('dark')
    expect(resolveTheme('dark', true)).toBe('dark')
    expect(resolveTheme('light', false)).toBe('light')
  })
})
