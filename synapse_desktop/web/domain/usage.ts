// What the status bar shows for one harness's usage: the dot's colour, the figure and the words a
// screen reader hears. Pure: the time is always passed in.

import type { UsageReading, UsageWindow } from '../../shared/usage.ts'

export type Band = 'green' | 'orange' | 'red'
export type Dot = Band | 'grey'

// Figures older than this are greyed out: the 5-minute reads have been failing for a while.
const OLD_MS = 3 * 60 * 60 * 1000

// The colour of a percentage, read as a whole number: up to 50 green, up to 85 orange, then red.
export function band(percent: number): Band {
  const whole = Math.round(percent)
  if (whole <= 50) return 'green'
  if (whole <= 85) return 'orange'
  return 'red'
}

// A window that has reset since the reading counts as unused.
export function percentNow(window: UsageWindow, now: Date): number {
  if (window.resetsAt === null) return window.percent
  const reset = Date.parse(window.resetsAt)
  return !Number.isNaN(reset) && reset <= now.getTime() ? 0 : window.percent
}

// The figure in the bar: for a limit, the highest percent of the windows that decide; for spend,
// the amount.
export function headline(reading: UsageReading, now: Date): number {
  if (reading.kind === 'spend') return reading.spend?.amount ?? 0
  return reading.windows
    .filter((window) => window.decides)
    .reduce((highest, window) => Math.max(highest, percentNow(window, now)), 0)
}

function isOld(reading: UsageReading, now: Date): boolean {
  if (reading.observedAt === null) return false
  const observed = Date.parse(reading.observedAt)
  return !Number.isNaN(observed) && now.getTime() - observed > OLD_MS
}

// Grey when the figure is a kept old one, older than 3 hours, or a spend (which has no limit).
export function dot(reading: UsageReading, now: Date): Dot {
  if (reading.state === 'stale' || isOld(reading, now)) return 'grey'
  if (reading.kind === 'spend') return 'grey'
  return band(headline(reading, now))
}

// Only a harness with figures has an item in the bar; the others are listed in the panel.
export function shownInBar(reading: UsageReading): boolean {
  return reading.state === 'ok' || reading.state === 'stale'
}

// `29%` or `$1.42`.
export function figureText(reading: UsageReading, now: Date): string {
  const figure = headline(reading, now)
  return reading.kind === 'spend' ? `$${figure.toFixed(2)}` : `${Math.round(figure)}%`
}

// How long ago the figures were read: `just now`, `12 min ago`, `4 h ago`, `2 d ago`.
export function ageText(observedAt: string, now: Date): string {
  const observed = Date.parse(observedAt)
  if (Number.isNaN(observed)) return ''
  const minutes = Math.max(0, Math.floor((now.getTime() - observed) / 60_000))
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  return `${Math.floor(hours / 24)} d ago`
}

// How old the figures are, in words for a screen reader: `4 hours`, `12 minutes`.
function ageWords(observedAt: string, now: Date): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - Date.parse(observedAt)) / 60_000))
  const [count, unit] = minutes < 60 ? [minutes, 'minute'] : [Math.floor(minutes / 60), 'hour']
  return `${count} ${unit}${count === 1 ? '' : 's'}`
}

// A window's name as a kind of limit: `Current session` as `session`, `Current week (all
// models)` as `weekly`, `5h` as it is.
function limitName(name: string): string {
  const short = name
    .replace(/\s*\(.*\)$/, '')
    .replace(/^Current /, '')
    .trim()
  return short === 'week' ? 'weekly' : short
}

function joinAnd(words: string[]): string {
  if (words.length <= 1) return words.join('')
  return `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`
}

// The screen-reader text of a bar item, e.g. `Claude: 29% used, highest of the session and weekly
// limits` or `Opencode: $1.42 spent today`.
export function describe(reading: UsageReading, now: Date): string {
  const figure = figureText(reading, now)
  let text: string
  if (reading.kind === 'spend') {
    const period = reading.spend?.period === 'session' ? 'this session' : 'today'
    text = `${reading.harness}: ${figure} spent ${period}`
  } else {
    const names = [
      ...new Set(reading.windows.filter((window) => window.decides).map((w) => limitName(w.name))),
    ]
    const which =
      names.length > 1
        ? `highest of the ${joinAnd(names)} limits`
        : names.length === 1
          ? `of the ${names[0]} limit`
          : ''
    text = `${reading.harness}: ${figure} used${which === '' ? '' : `, ${which}`}`
  }
  if (reading.observedAt !== null && (reading.state === 'stale' || isOld(reading, now))) {
    text += `, figure is ${ageWords(reading.observedAt, now)} old`
  }
  return text
}
