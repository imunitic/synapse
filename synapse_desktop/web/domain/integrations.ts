// How an integration is told to a person: what it is, and what the button that
// changes it is called.

import type { Harness, IntegrationState } from '../../shared/transport.ts'

export const HARNESS_NAMES: Record<Harness, string> = {
  Claude: 'Claude Code',
  Codex: 'Codex',
  Opencode: 'OpenCode',
}

const LABELS: Record<IntegrationState, string> = {
  absent: 'Not installed',
  current: 'Installed, up to date',
  different: 'Installed from another copy or version',
  broken: 'Its hook program is missing',
  installed: 'Installed',
  newer: "Installed, newer than this app's Synapse",
}

export function stateLabel(state: IntegrationState): string {
  return LABELS[state]
}

// What a card offers for a state: a button, and the command it runs in a terminal tab.
export interface InstallOffer {
  label: string
  command: string
}

// The packages and their setup tools: Synapse from npm, so that the hook path in a harness is
// the one the npm launchers keep, whatever happens to this app.
const PACKAGES = '@imunitic/synapse@latest @imunitic/synapse-pipeline@latest'

// The command that installs, repairs or updates Synapse for a harness: the npm packages,
// then each one's `configure` for the harness.
export function installCommand(harness: Harness): string {
  const name = harness.toLowerCase()
  return `npm install -g ${PACKAGES} && synapse-setup configure ${name} && synapse-pipeline-setup configure ${name}`
}

// What to offer for a harness whose Synapse is in `state`. Nothing when it is current or newer
// than the app's, and nothing when there is no way to tell, since then it is not known to need
// anything.
export function installOffer(harness: Harness, state: IntegrationState): InstallOffer | null {
  switch (state) {
    case 'absent':
      return { label: 'Install', command: installCommand(harness) }
    case 'broken':
      return { label: 'Repair', command: installCommand(harness) }
    case 'different':
      return { label: 'Update', command: installCommand(harness) }
    case 'current':
    case 'newer':
    case 'installed':
      return null
  }
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
