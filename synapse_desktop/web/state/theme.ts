// The theme, put on the page as `data-theme` on the root element and kept in the browser, which
// is a convenience of the person looking at it and not a setting of the app. With System, the
// page follows the computer and changes when it does.

import {
  DEFAULT_THEME,
  parseTheme,
  resolveTheme,
  type Theme,
  type ThemeChoice,
} from '../domain/theme.ts'

const KEY = 'synapse-desktop.theme'
const LIGHT = '(prefers-color-scheme: light)'

let choice: ThemeChoice = DEFAULT_THEME
const listeners = new Set<(theme: Theme) => void>()

function stored(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}

function systemPrefersLight(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia(LIGHT).matches
}

function apply(): void {
  const theme = resolveTheme(choice, systemPrefersLight())
  document.documentElement.dataset.theme = theme
  for (const listener of listeners) listener(theme)
}

export function currentThemeChoice(): ThemeChoice {
  return choice
}

export function currentTheme(): Theme {
  return resolveTheme(choice, systemPrefersLight())
}

export function startTheme(): void {
  choice = parseTheme(stored())
  apply()
  if (typeof window.matchMedia === 'function') {
    window.matchMedia(LIGHT).addEventListener('change', () => {
      if (choice === 'system') apply()
    })
  }
}

export function setTheme(next: ThemeChoice): void {
  choice = next
  apply()
  try {
    localStorage.setItem(KEY, next)
  } catch {
    // The theme holds until the page is closed.
  }
}

// What a program that draws its own colours, as a terminal does, hears when the theme changes.
export function onThemeChange(listener: (theme: Theme) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
