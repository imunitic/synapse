// The size of the text, put on the page and kept in the browser, which is a convenience
// of the person looking at it and not a setting of the app. A page that cannot be written
// to keeps the size for as long as it is open.

import { DEFAULT_TEXT_SIZE, parseTextSize } from '../domain/text-size.ts'

const KEY = 'synapse-desktop.text-size'

let current = DEFAULT_TEXT_SIZE
const listeners = new Set<(percent: number) => void>()

export function currentTextSize(): number {
  return current
}

function stored(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}

// Put on the page: every size of the text is in rem, so this one value scales them all.
export function applyTextSize(percent: number): void {
  current = percent
  document.documentElement.style.fontSize = `${percent}%`
  for (const listener of listeners) listener(percent)
}

export function startTextSize(): void {
  applyTextSize(parseTextSize(stored()))
}

export function setTextSize(percent: number): void {
  applyTextSize(percent)
  try {
    localStorage.setItem(KEY, String(percent))
  } catch {
    // The size holds until the page is closed.
  }
}

// What a program that draws its own text, as a terminal does, hears when the size changes.
export function onTextSizeChange(listener: (percent: number) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
