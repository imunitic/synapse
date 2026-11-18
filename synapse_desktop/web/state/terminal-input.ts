// How the Changes sidebar reaches the terminal of a session: each terminal view registers how to send
// a prompt to its session, and whether a harness runs in it, while it is on the page. A review is
// pasted the way a person's paste is, and submitted with Enter only where the session's own program
// is the harness: in a shell, the harness started in it may have ended, and the shell would run the
// lines as commands.

export interface TerminalInput {
  // Pastes the text into the session's terminal, and submits it when `submits` says it is safe to.
  send: (text: string) => void
  // Whether the session's own program is a harness, so that Enter goes to its prompt.
  submits: boolean
  // Whether a harness runs in the session: pasted text goes to its prompt, not to a shell.
  harness: boolean
}

// Kept on the global object, so that a copy of this module loaded again in development (a hot
// reload) finds the terminals that registered with the one before: a terminal registers once, when
// it is made, and is not made again for a new copy of the module.
interface Registry {
  inputs: Map<string, TerminalInput>
  listeners: Set<() => void>
}
const global = globalThis as typeof globalThis & { __synapseTerminalInput?: Registry }
global.__synapseTerminalInput ??= { inputs: new Map(), listeners: new Set() }
const { inputs, listeners } = global.__synapseTerminalInput

function told(): void {
  for (const listener of listeners) listener()
}

// Registers a session's terminal; what it returns unregisters it, if it is still the one registered.
export function registerTerminal(session: string, input: TerminalInput): () => void {
  inputs.set(session, input)
  told()
  return () => {
    if (inputs.get(session) !== input) return
    inputs.delete(session)
    told()
  }
}

export function setHarness(session: string, harness: boolean): void {
  const input = inputs.get(session)
  if (input === undefined || input.harness === harness) return
  input.harness = harness
  told()
}

export function terminalInput(session: string): TerminalInput | null {
  return inputs.get(session) ?? null
}

// Told when a terminal comes or goes, or a harness starts in one; the way to stop is what this
// returns.
export function onTerminalInputChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
