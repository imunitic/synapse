// What `synapse doctor` found, as the app uses it: which harnesses can be used, and what
// needs doing, with a way to do it.

import type { Diagnosis, DoctorFinding, Harness } from '../../shared/transport.ts'

export const HARNESS_LIST: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

// The key of the check of each harness.
const HARNESS_KEYS: Record<Harness, string> = {
  Claude: 'claude',
  Codex: 'codex',
  Opencode: 'opencode',
}

// Whether a harness is there, or not known yet. It is not known while the check is made and
// when it could not be made, and then nothing is held back for it.
export type Availability = 'installed' | 'missing' | 'unknown'

export function harnessAvailability(diagnosis: Diagnosis | null): Record<Harness, Availability> {
  const result: Record<Harness, Availability> = {
    Claude: 'unknown',
    Codex: 'unknown',
    Opencode: 'unknown',
  }
  if (diagnosis === null) return result
  for (const harness of HARNESS_LIST) {
    const finding = diagnosis.findings.find((f) => f.key === HARNESS_KEYS[harness])
    // The value of a program's check is where it was found.
    if (finding !== undefined) result[harness] = finding.value === '' ? 'missing' : 'installed'
  }
  return result
}

// The harness to use when none is asked for: the one chosen as the default, unless it is
// missing, else the first there is, else the default or Claude Code, which the check could
// not say anything about.
export function effectiveHarness(
  chosen: Harness | null,
  availability: Record<Harness, Availability>,
): Harness {
  if (chosen !== null && availability[chosen] !== 'missing') return chosen
  return HARNESS_LIST.find((h) => availability[h] === 'installed') ?? chosen ?? 'Claude'
}

export interface Install {
  label: string
  command: string
}

// What installs each harness. They are shown, and never run for the person.
export const HARNESS_INSTALLS: Record<Harness, Install> = {
  Claude: { label: 'Claude Code', command: 'npm install -g @anthropic-ai/claude-code' },
  Codex: { label: 'Codex', command: 'npm install -g @openai/codex' },
  Opencode: { label: 'OpenCode', command: 'npm install -g opencode-ai' },
}

export const PIPELINE_INSTALL: Install = {
  label: 'synapse-pipeline',
  command: 'npm install -g @imunitic/synapse-pipeline',
}

export type Fix =
  // A page of the settings that puts it right.
  | { kind: 'settings'; section: 'vault' | 'integrations'; label: string }
  // A command to run in a terminal, which the person is shown and can copy.
  | { kind: 'command'; label: string; command: string }

export interface Attention {
  key: string
  severity: 'error' | 'warning'
  title: string
  detail: string
  fixes: Fix[]
  // A warning can be put aside; what stops Synapse working cannot.
  dismissible: boolean
}

const TITLES: Record<string, string> = {
  git: 'Git',
  pipeline: 'Pipelines',
  harness: 'Harness',
  claude: 'Claude Code',
  codex: 'Codex',
  opencode: 'OpenCode',
  config: 'Configuration',
  vault: 'Vault',
  'vault-index': 'Vault index',
  hooks: 'Hooks',
  'hook-wiring': 'Hook wiring',
}

function fixesFor(finding: DoctorFinding): Fix[] {
  switch (finding.key) {
    case 'harness':
      return HARNESS_LIST.map((h) => ({
        kind: 'command',
        label: HARNESS_INSTALLS[h].label,
        command: HARNESS_INSTALLS[h].command,
      }))
    case 'claude':
    case 'codex':
    case 'opencode':
    case 'hooks':
    case 'hook-wiring':
      return [{ kind: 'settings', section: 'integrations', label: 'Install Synapse in a harness' }]
    case 'config':
    case 'vault':
      return [{ kind: 'settings', section: 'vault', label: 'Choose a vault' }]
    case 'vault-index':
      return [{ kind: 'settings', section: 'vault', label: 'Open the vault settings' }]
    case 'pipeline':
      return [{ kind: 'command', label: PIPELINE_INSTALL.label, command: PIPELINE_INSTALL.command }]
    default:
      return []
  }
}

// What is not fine, errors before warnings and each in the order it was found, without the
// warnings that were put aside. A harness that is missing is only said when the check as a
// whole says there is none, since one of several missing is nobody's fault. Without a
// configuration file and without a vault is one thing to do, since choosing the vault writes
// the file.
export function attentionOf(diagnosis: Diagnosis, dismissed: ReadonlySet<string>): Attention[] {
  const found: Attention[] = []
  for (const finding of diagnosis.findings) {
    if (finding.status === 'ok') continue
    const isHarness = HARNESS_LIST.some((h) => HARNESS_KEYS[h] === finding.key)
    if (isHarness && finding.value === '') continue
    if (
      finding.key === 'config' &&
      diagnosis.findings.some((f) => f.key === 'vault' && f.status === 'fail')
    ) {
      continue
    }
    const severity = finding.status === 'fail' ? 'error' : 'warning'
    const dismissible = severity === 'warning'
    if (dismissible && dismissed.has(finding.key)) continue
    found.push({
      key: finding.key,
      severity,
      title: TITLES[finding.key] ?? finding.name,
      detail: finding.detail,
      fixes: fixesFor(finding),
      dismissible,
    })
  }
  return [
    ...found.filter((a) => a.severity === 'error'),
    ...found.filter((a) => a.severity === 'warning'),
  ]
}

// The warnings that were put aside and are still there.
export function dismissedWarnings(diagnosis: Diagnosis, dismissed: ReadonlySet<string>): string[] {
  return diagnosis.findings
    .filter((f) => f.status === 'warn' && dismissed.has(f.key))
    .map((f) => f.key)
}
