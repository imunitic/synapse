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

// What a card offers for a state: a button, the command it runs in a terminal tab, and, for a
// setup that is not supported, why, said on the card before the button.
export interface InstallOffer {
  label: string
  command: string
  warning?: string
}

// The npm version that installing puts in a harness: this app's own, so that a harness runs the
// Synapse the app bundles, and a version installed any other way is not supported. A development
// build, whose version is 0.0.0-dev or unknown, has no packages of its own on npm and installs
// the latest.
export function packageVersion(version: string | null): string {
  return version === null || version.endsWith('-dev') ? 'latest' : version
}

// The command that installs, repairs or updates Synapse for a harness: the npm packages at this
// app's version, from npm so that the hook path in a harness is the one the npm launchers keep
// whatever happens to this app, then each one's `configure` for the harness.
export function installCommand(harness: Harness, version: string | null): string {
  const name = harness.toLowerCase()
  const at = packageVersion(version)
  return `npm install -g @imunitic/synapse@${at} @imunitic/synapse-pipeline@${at} && synapse-setup configure ${name} && synapse-pipeline-setup configure ${name}`
}

// What to offer for a harness whose Synapse is in `state`, for an app whose Synapse is
// `version`. Nothing when it is current, and nothing when there is no way to tell, since then
// it is not known to need anything. A newer one is not supported: a released app offers its own
// version in its place, a development build offers nothing.
export function installOffer(
  harness: Harness,
  state: IntegrationState,
  version: string | null,
): InstallOffer | null {
  const command = installCommand(harness, version)
  switch (state) {
    case 'absent':
      return { label: 'Install', command }
    case 'broken':
      return { label: 'Repair', command }
    case 'different':
      return { label: 'Update', command }
    case 'newer':
      if (packageVersion(version) === 'latest') return null
      return {
        label: `Install ${version}`,
        command,
        warning: `This is newer than the Synapse of this app, ${version}, and is not supported: its skills and hooks may not work with the app's programs. Installing replaces it with this app's version.`,
      }
    case 'current':
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
