// What the cards of the Terminals page were last showing, kept in the browser so that they open
// that way again: which list of a harness's card, and whether a card is open. What the browser keeps
// is only a convenience: when it cannot be read or written a card opens on the folders, and a
// harness's card is shut.

import type { Harness } from '../../shared/transport.ts'
import type { Memory } from './recent.ts'

export type LaunchView = 'folders' | 'sessions'

const key = (harness: Harness) => `synapse-desktop.launch-view.${harness}`

function storage(): Memory | null {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}

export function launchView(harness: Harness, memory: Memory | null = storage()): LaunchView {
  try {
    return memory?.getItem(key(harness)) === 'sessions' ? 'sessions' : 'folders'
  } catch {
    return 'folders'
  }
}

export function rememberLaunchView(
  harness: Harness,
  view: LaunchView,
  memory: Memory | null = storage(),
): void {
  try {
    memory?.setItem(key(harness), view)
  } catch {
    // Nothing is kept, and nothing else is the worse for it.
  }
}

export type LaunchCard = 'Shell' | Harness

const openKey = (card: LaunchCard) => `synapse-desktop.launch-open.${card}`

// A harness's card is shut until it was opened, since its lists are long; the shell's is open, since
// its form is what the page is for.
export function launchOpen(card: LaunchCard, memory: Memory | null = storage()): boolean {
  try {
    const kept = memory?.getItem(openKey(card))
    return kept === 'true' ? true : kept === 'false' ? false : card === 'Shell'
  } catch {
    return card === 'Shell'
  }
}

export function rememberLaunchOpen(
  card: LaunchCard,
  open: boolean,
  memory: Memory | null = storage(),
): void {
  try {
    memory?.setItem(openKey(card), String(open))
  } catch {
    // Nothing is kept, and nothing else is the worse for it.
  }
}
