import { describe, expect, it } from 'vitest'
import { clampWidth, readStoredWidth, stepWidth, MAIN_MIN_PX } from './panel-width.ts'

const limits = { min: 300, max: 900, initial: 460 }
const roomy = { current: 460, mainWidth: 2000 }

describe('readStoredWidth', () => {
  it('uses a stored value inside the limits', () => {
    expect(readStoredWidth('520', limits)).toBe(520)
    expect(readStoredWidth('300', limits)).toBe(300)
    expect(readStoredWidth('900', limits)).toBe(900)
  })

  it('gives the initial width when nothing usable is stored', () => {
    expect(readStoredWidth(null, limits)).toBe(460)
    expect(readStoredWidth('', limits)).toBe(460)
    expect(readStoredWidth('wide', limits)).toBe(460)
    expect(readStoredWidth('299', limits)).toBe(460)
    expect(readStoredWidth('901', limits)).toBe(460)
  })
})

describe('clampWidth', () => {
  it('keeps the width within the limits', () => {
    expect(clampWidth(100, limits, roomy)).toBe(300)
    expect(clampWidth(1200, limits, roomy)).toBe(900)
    expect(clampWidth(600, limits, roomy)).toBe(600)
  })

  it('lowers a wide width so the main page keeps its room', () => {
    // The panel is 460 and the main page 600: the panel can grow by 240.
    expect(clampWidth(800, limits, { current: 460, mainWidth: 600 })).toBe(700)
    expect(600 - (700 - 460)).toBe(MAIN_MIN_PX)
  })

  it('never goes below the minimum for the main page', () => {
    expect(clampWidth(800, limits, { current: 320, mainWidth: 200 })).toBe(300)
  })
})

describe('stepWidth', () => {
  it('moves by 16, or 64 with Shift', () => {
    expect(stepWidth(460, 1, false, limits, 2000)).toBe(476)
    expect(stepWidth(460, -1, false, limits, 2000)).toBe(444)
    expect(stepWidth(460, 1, true, limits, 2000)).toBe(524)
    expect(stepWidth(460, -1, true, limits, 2000)).toBe(396)
  })

  it('stops at a limit it would pass', () => {
    expect(stepWidth(890, 1, true, limits, 2000)).toBe(900)
    expect(stepWidth(310, -1, true, limits, 2000)).toBe(300)
    expect(stepWidth(460, 1, true, limits, 370)).toBe(470)
  })
})
