// How an integration is told to a person: what it is, and what the button that
// changes it is called.

import type { Harness, IntegrationState } from '../../shared/transport.ts'

export const HARNESS_NAMES: Record<Harness, string> = {
  Claude: 'Claude Code',
  Codex: 'Codex',
  Opencode: 'OpenCode',
}

const STATES: Record<IntegrationState, { label: string; action: string }> = {
  absent: { label: 'Not installed', action: 'Install' },
  current: { label: 'Installed, up to date', action: 'Reinstall' },
  different: { label: 'Installed from another copy or version', action: 'Update' },
  broken: { label: 'Its hook program is missing', action: 'Repair' },
  installed: { label: 'Installed', action: 'Reinstall' },
  newer: { label: "Installed, newer than this app's Synapse", action: 'Update' },
}

export function stateLabel(state: IntegrationState): string {
  return STATES[state].label
}

// Whether pressing the button would put an older Synapse over a newer one.
export function isDowngrade(state: IntegrationState): boolean {
  return state === 'newer'
}

export function actionLabel(state: IntegrationState): string {
  return STATES[state].action
}

// What installing writes for a harness, which the person is told before it is.
export function writesFor(harness: Harness): string[] {
  switch (harness) {
    case 'Claude':
      return [
        '~/.claude/settings.json: the hooks of Synapse are merged in and a copy is kept as settings.json.bak',
        '~/.claude/skills and ~/.claude/commands: the skills and commands of Synapse',
      ]
    case 'Codex':
      return [
        '~/.codex/hooks.json: the hooks of Synapse are merged in and a copy is kept as hooks.json.bak',
        '~/.codex/skills: the skills of Synapse',
      ]
    case 'Opencode':
      return [
        '~/.config/opencode/plugin/synapse.js: the plugin of Synapse',
        '~/.config/opencode/skill and ~/.config/opencode/command: the skills and commands of Synapse',
      ]
  }
}
