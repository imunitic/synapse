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
}

export function stateLabel(state: IntegrationState): string {
  return STATES[state].label
}

export function actionLabel(state: IntegrationState): string {
  return STATES[state].action
}
