// The groups of what the vault wants decided, put under the kind of note they are about: a design
// note is talked through and then compiled into a task note, which is worked through. Pure, so
// the page only has to show it.

import type { AttentionGroup } from './attention.ts'

export interface VaultSection {
  key: 'designs' | 'tasks' | 'other'
  title: string
  // One line on what the notes of the kind are.
  about: string
  groups: (AttentionGroup & { about: string | null })[]
}

// What each group is, by the key `synapse status` gives it, and the kind of note it holds.
const KNOWN: Record<string, { section: 'designs' | 'tasks'; about: string }> = {
  'vault:discussing': { section: 'designs', about: 'Still being worked out' },
  'vault:ready_uncompiled': { section: 'designs', about: 'Ready, and no task note has been made' },
  'vault:open_questions': { section: 'designs', about: 'Ready, with a question still open' },
  'vault:in_progress': { section: 'tasks', about: 'Items still to do' },
  'vault:awaiting_review': { section: 'tasks', about: 'Every item done, waiting to be signed off' },
}

const SECTIONS: Record<VaultSection['key'], { title: string; about: string }> = {
  designs: {
    title: 'Design notes',
    about: 'What is being decided, before anything is built',
  },
  tasks: {
    title: 'Task notes',
    about: 'What is being built, from a design note that was made ready',
  },
  other: { title: 'Other', about: '' },
}

// The sections that have a group, design notes first, each with its groups in the order given.
export function vaultSections(groups: readonly AttentionGroup[]): VaultSection[] {
  const order: VaultSection['key'][] = ['designs', 'tasks', 'other']
  return order
    .map((key) => ({
      key,
      ...SECTIONS[key],
      groups: groups
        .filter((group) => (KNOWN[group.key]?.section ?? 'other') === key)
        .map((group) => ({ ...group, about: KNOWN[group.key]?.about ?? null })),
    }))
    .filter((section) => section.groups.length > 0)
}

// How many notes a section lists.
export function noteCount(section: VaultSection): number {
  return section.groups.reduce((sum, group) => sum + group.items.length, 0)
}
