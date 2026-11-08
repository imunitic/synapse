// Which list of a harness's card on the Terminals page was last shown, kept in the browser so
// that the card opens on it again. What the browser keeps is only a convenience: when it cannot
// be read or written the card opens on the folders.

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
