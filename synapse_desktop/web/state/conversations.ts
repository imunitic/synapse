// The conversations of harnesses each terminal session follows, for the Activity tab of the Changes
// sidebar: each terminal view publishes the lines of the session files it follows as they grow, and
// takes them away when it goes. Kept on the global object, as terminal-input.ts is, so that a copy
// of this module loaded again in development finds what was published before.

import type { FollowedHarness } from '../domain/activity.ts'

// A conversation that is followed: the lines of the session file of a harness.
export interface FollowedConversation {
  id: string
  harness: FollowedHarness
  cwd: string
  lines: string[]
}

interface Store {
  bySession: Map<string, readonly FollowedConversation[]>
  listeners: Set<() => void>
}
const global = globalThis as typeof globalThis & { __synapseConversations?: Store }
global.__synapseConversations ??= { bySession: new Map(), listeners: new Set() }
const { bySession, listeners } = global.__synapseConversations

const NONE: readonly FollowedConversation[] = []

export function setConversations(session: string, followed: readonly FollowedConversation[]): void {
  if (followed.length === 0) bySession.delete(session)
  else bySession.set(session, followed)
  for (const listener of listeners) listener()
}

export function conversationsOf(session: string): readonly FollowedConversation[] {
  return bySession.get(session) ?? NONE
}

// Told when a session's conversations change; the way to stop is what this returns.
export function onConversationsChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
