import { describe as group, expect, it } from 'vitest'
import type { UsageReading } from '../../shared/usage.ts'
import {
  ageText,
  band,
  describe,
  dot,
  figureText,
  headline,
  percentNow,
  shownInBar,
} from './usage.ts'

const now = new Date('2026-11-25T12:00:00Z')

function claude(overrides: Partial<UsageReading> = {}): UsageReading {
  return {
    harness: 'Claude',
    kind: 'limit',
    windows: [
      { name: 'Current session', percent: 29, resetsAt: '2026-11-25T15:00:00Z', decides: true },
      {
        name: 'Current week (all models)',
        percent: 12,
        resetsAt: '2026-11-28T16:59:00Z',
        decides: true,
      },
      { name: 'Current week (Fable)', percent: 90, resetsAt: null, decides: false },
    ],
    spend: null,
    observedAt: '2026-11-25T11:58:00Z',
    state: 'ok',
    reason: null,
    ...overrides,
  }
}

const opencode: UsageReading = {
  harness: 'Opencode',
  kind: 'spend',
  windows: [],
  spend: { amount: 1.42, period: 'today' },
  observedAt: '2026-11-25T11:58:00Z',
  state: 'ok',
  reason: null,
}

group('band', () => {
  it('reads the percentage as a whole number against 50 and 85', () => {
    expect(band(0)).toBe('green')
    expect(band(50.4)).toBe('green')
    expect(band(50.5)).toBe('orange')
    expect(band(85)).toBe('orange')
    expect(band(85.5)).toBe('red')
    expect(band(120)).toBe('red')
  })
})

group('headline', () => {
  it('is the highest percent among the windows that decide', () => {
    expect(headline(claude(), now)).toBe(29)
  })

  it('counts a window whose reset has passed as 0', () => {
    const reading = claude()
    reading.windows[0] = { ...reading.windows[0]!, resetsAt: '2026-11-25T11:00:00Z' }
    expect(headline(reading, now)).toBe(12)
  })

  it('is the amount for spend', () => {
    expect(headline(opencode, now)).toBe(1.42)
  })
})

group('percentNow', () => {
  it('is the percent until the reset and 0 once it has passed', () => {
    const window = claude().windows[0]!
    expect(percentNow(window, now)).toBe(29)
    expect(percentNow({ ...window, resetsAt: '2026-11-25T11:00:00Z' }, now)).toBe(0)
    expect(percentNow({ ...window, resetsAt: null }, now)).toBe(29)
  })
})

group('dot', () => {
  it('is the band of the headline for a fresh limit', () => {
    expect(dot(claude(), now)).toBe('green')
    const reading = claude()
    reading.windows[1] = { ...reading.windows[1]!, percent: 70 }
    expect(dot(reading, now)).toBe('orange')
  })

  it('is grey for an ok reading more than 3 hours old', () => {
    expect(dot(claude({ observedAt: '2026-11-25T08:59:00Z' }), now)).toBe('grey')
    expect(dot(claude({ observedAt: '2026-11-25T09:00:00Z' }), now)).toBe('green')
  })

  it('is grey for a stale reading and for spend', () => {
    expect(dot(claude({ state: 'stale' }), now)).toBe('grey')
    expect(dot(opencode, now)).toBe('grey')
  })
})

group('shownInBar', () => {
  it('shows only ok and stale readings', () => {
    expect(shownInBar(claude())).toBe(true)
    expect(shownInBar(claude({ state: 'stale' }))).toBe(true)
    expect(shownInBar(claude({ state: 'not-installed' }))).toBe(false)
    expect(shownInBar(claude({ state: 'not-signed-in' }))).toBe(false)
    expect(shownInBar(claude({ state: 'unavailable' }))).toBe(false)
  })
})

group('figureText', () => {
  it('writes a percent whole and an amount in dollars with two decimals', () => {
    expect(figureText(claude(), now)).toBe('29%')
    expect(figureText(opencode, now)).toBe('$1.42')
    expect(figureText({ ...opencode, spend: { amount: 3, period: 'today' } }, now)).toBe('$3.00')
  })
})

group('describe', () => {
  it('names the limits a figure is the highest of', () => {
    expect(describe(claude(), now)).toBe(
      'Claude: 29% used, highest of the session and weekly limits',
    )
  })

  it('says what was spent and when', () => {
    expect(describe(opencode, now)).toBe('Opencode: $1.42 spent today')
  })

  it('says how old a stale figure is', () => {
    expect(describe(claude({ state: 'stale', observedAt: '2026-11-25T08:00:00Z' }), now)).toBe(
      'Claude: 29% used, highest of the session and weekly limits, figure is 4 hours old',
    )
  })
})

group('ageText', () => {
  it('says how long ago in minutes, hours or days', () => {
    expect(ageText('2026-11-25T11:59:30Z', now)).toBe('just now')
    expect(ageText('2026-11-25T11:48:00Z', now)).toBe('12 min ago')
    expect(ageText('2026-11-25T08:00:00Z', now)).toBe('4 h ago')
    expect(ageText('2026-11-23T12:00:00Z', now)).toBe('2 d ago')
  })
})
