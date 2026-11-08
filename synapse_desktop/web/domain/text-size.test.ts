import { describe, expect, it } from 'vitest'
import { DEFAULT_TEXT_SIZE, parseTextSize, scaledPixels, TEXT_SIZES } from './text-size.ts'

describe('the size of the text', () => {
  it('is a little over the browser size by default, and the default is one of those on offer', () => {
    expect(DEFAULT_TEXT_SIZE).toBeGreaterThan(100)
    expect(TEXT_SIZES.map((s) => s.percent)).toContain(DEFAULT_TEXT_SIZE)
    expect(TEXT_SIZES.find((s) => s.percent === DEFAULT_TEXT_SIZE)?.label).toBe('Default')
  })

  it('has every size on offer in order, and each has a name', () => {
    const percents = TEXT_SIZES.map((s) => s.percent)
    expect([...percents].sort((a, b) => a - b)).toEqual(percents)
    for (const size of TEXT_SIZES) expect(size.label).not.toBe('')
  })

  it('is read back when it is one on offer, and is the default for anything else', () => {
    expect(parseTextSize('125')).toBe(125)
    expect(parseTextSize('112.5')).toBe(112.5)
    expect(parseTextSize(null)).toBe(DEFAULT_TEXT_SIZE)
    expect(parseTextSize('')).toBe(DEFAULT_TEXT_SIZE)
    expect(parseTextSize('banana')).toBe(DEFAULT_TEXT_SIZE)
    expect(parseTextSize('7')).toBe(DEFAULT_TEXT_SIZE)
    expect(parseTextSize('9999')).toBe(DEFAULT_TEXT_SIZE)
  })

  it('makes a size in pixels what it is at the size of the page, in whole pixels', () => {
    expect(scaledPixels(13, 100)).toBe(13)
    expect(scaledPixels(13, 112.5)).toBe(15)
    expect(scaledPixels(13, 150)).toBe(20)
  })
})
