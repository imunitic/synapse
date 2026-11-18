// How an integration is told to a person: what it is, and what the button that
// changes it is called.

import type { Harness, IntegrationState } from '../../shared/transport.ts'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

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

// The harnesses an install or update covers: every one that is available on this machine. The npm
// packages are global, so the hook programs of every harness move to the new version at once;
// configuring each keeps its skills, commands and hook files at that version too.
export function harnessesToConfigure(isMissing: (harness: Harness) => boolean): Harness[] {
  return HARNESSES.filter((harness) => !isMissing(harness))
}

// The command that installs, repairs or updates Synapse for harnesses: the npm packages at this
// app's version, from npm so that the hook path in a harness is the one the npm launchers keep
// whatever happens to this app, then each one's `configure` for each of the harnesses.
export function installCommand(harnesses: readonly Harness[], version: string | null): string {
  const at = packageVersion(version)
  const configure = harnesses
    .map((h) => h.toLowerCase())
    .flatMap((name) => [
      `synapse-setup configure ${name}`,
      `synapse-pipeline-setup configure ${name}`,
    ])
  return [
    `npm install -g @imunitic/synapse@${at} @imunitic/synapse-pipeline@${at}`,
    ...configure,
  ].join(' && ')
}

// Whether a harness in `state` has something to be done to it, for an app whose Synapse is
// `version`. Nothing when it is current, and nothing when there is no way to tell, since then it
// is not known to need anything. A newer one is not supported: a released app puts its own
// version in its place, a development build leaves it.
function needsInstalling(state: IntegrationState, version: string | null): boolean {
  switch (state) {
    case 'absent':
    case 'broken':
    case 'different':
      return true
    case 'newer':
      return packageVersion(version) !== 'latest'
    case 'current':
    case 'installed':
      return false
  }
}

// What the one button of the page offers, for the harnesses `states` says of and the `configured`
// among them that are available: null when none of them needs anything.
export function installOffer(
  states: Readonly<Record<Harness, IntegrationState>>,
  configured: readonly Harness[],
  version: string | null,
): InstallOffer | null {
  const needing = configured.filter((h) => needsInstalling(states[h], version))
  if (needing.length === 0) return null
  const every = (state: IntegrationState) => needing.every((h) => states[h] === state)
  const label = every('absent') ? 'Install' : every('broken') ? 'Repair' : 'Update'
  const newer = configured.filter((h) => states[h] === 'newer')
  return {
    label: `${label} in all harnesses`,
    command: installCommand(configured, version),
    ...(newer.length > 0 && packageVersion(version) !== 'latest'
      ? {
          warning: `${newer.map((h) => HARNESS_NAMES[h]).join(', ')} has a Synapse newer than the one of this app, ${version}, which is not supported: its skills and hooks may not work with the app's programs. This replaces it with this app's version.`,
        }
      : {}),
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
