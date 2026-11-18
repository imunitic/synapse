// The colours of the app: dark or light, or whichever the computer is set to. The colours
// themselves are CSS variables in index.css; this is only which set is in use.

export type Theme = 'dark' | 'light'
export type ThemeChoice = Theme | 'system'

export const THEMES: readonly { choice: ThemeChoice; label: string }[] = [
  { choice: 'dark', label: 'Dark' },
  { choice: 'light', label: 'Light' },
  { choice: 'system', label: 'System' },
]

export const DEFAULT_THEME: ThemeChoice = 'dark'

// A choice that was kept, if it is one of those on offer, else the default.
export function parseTheme(stored: string | null): ThemeChoice {
  return THEMES.some((theme) => theme.choice === stored) ? (stored as ThemeChoice) : DEFAULT_THEME
}

export function resolveTheme(choice: ThemeChoice, systemPrefersLight: boolean): Theme {
  if (choice === 'system') return systemPrefersLight ? 'light' : 'dark'
  return choice
}
