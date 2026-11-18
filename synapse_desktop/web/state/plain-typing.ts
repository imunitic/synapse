// Typing in the app's fields as typed. In the desktop app the page runs in WebKit, which follows
// macOS's "Capitalize words automatically" and "Correct spelling automatically": a definition name,
// a path or a model typed in a field would be changed as it is typed. Every input and text area is
// told not to, when it takes the focus, unless it says otherwise itself. The browser build is not
// affected: Chromium does neither.

// What `makePlain` needs of an element, so that it can be told apart from the page.
export interface Field {
  tagName: string
  hasAttribute: (name: string) => boolean
  setAttribute: (name: string, value: string) => void
}

const ATTRIBUTES = ['autocapitalize', 'autocorrect'] as const

// Turns capitalizing and correcting off on an input or a text area that has not set them itself.
export function makePlain(field: Field): void {
  if (field.tagName !== 'INPUT' && field.tagName !== 'TEXTAREA') return
  for (const name of ATTRIBUTES) {
    if (!field.hasAttribute(name)) field.setAttribute(name, 'off')
  }
}

// Every field that takes the focus, now and later, is made plain before anything is typed in it.
export function startPlainTyping(): void {
  document.addEventListener('focusin', (event) => {
    if (event.target instanceof HTMLElement) makePlain(event.target)
  })
}
