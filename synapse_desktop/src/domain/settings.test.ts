import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import {
  clearSetting,
  groupOf,
  isWholeNumber,
  joinItems,
  listItems,
  loadSettings,
  settingsOf,
  saveSetting,
} from './settings.ts'

function withCli(answer: (args: string[]) => CliResult, seen: string[][] = []): Transport {
  const base = fakeTransport({
    files: {},
    paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
  })
  return {
    ...base,
    cli: (binary, args) => {
      expect(binary).toBe('synapse')
      seen.push(args)
      return Promise.resolve(answer(args))
    },
  }
}

const LISTED = JSON.stringify({
  format: 'synapse-config/v1',
  conf: { read: '/h/.claude/synapse.conf', write: '/h/.claude/synapse.conf' },
  settings: [
    {
      key: 'SYNAPSE_VAULT_PUSH_EVERY',
      kind: 'number',
      description: 'How many commits pile up.',
      default: '5',
      required: false,
      environment: true,
      value: '2',
      source: 'environment',
      file: '/h/.claude/synapse.conf',
      file_value: '7',
      shadowed: true,
    },
    {
      key: 'SYNAPSE_VAULT_DIR',
      kind: 'path',
      description: 'The vault.',
      default: null,
      required: true,
      environment: true,
      value: null,
      source: 'unset',
      file: null,
      file_value: null,
      shadowed: false,
    },
  ],
})

describe('loadSettings', () => {
  it('reads what config list answers', async () => {
    const seen: string[][] = []
    const loaded = await loadSettings(
      withCli(() => ({ code: 0, stdout: LISTED, stderr: '' }), seen),
    )
    expect(seen).toEqual([['config', 'list', '--format', 'json']])
    expect(loaded.write).toBe('/h/.claude/synapse.conf')
    expect(loaded.settings.map((s) => [s.key, s.source, s.shadowed])).toEqual([
      ['SYNAPSE_VAULT_PUSH_EVERY', 'environment', true],
      ['SYNAPSE_VAULT_DIR', 'unset', false],
    ])
    expect(loaded.settings[0]).toMatchObject({ file_value: '7', value: '2', default: '5' })
  })

  it('fails with the program own reason, and on a form it does not know', async () => {
    await expect(
      loadSettings(withCli(() => ({ code: 1, stdout: '', stderr: 'synapse-config: boom\n' }))),
    ).rejects.toThrow('synapse-config: boom')
    await expect(
      loadSettings(withCli(() => ({ code: 0, stdout: 'not json', stderr: '' }))),
    ).rejects.toThrow(/did not answer JSON/)
    await expect(
      loadSettings(
        withCli(() => ({
          code: 0,
          stdout: JSON.stringify({ format: 'synapse-config/v2' }),
          stderr: '',
        })),
      ),
    ).rejects.toThrow(/does not know/)
  })
})

describe('changing a setting', () => {
  it('sends set and unset with the key, and the value as one argument', async () => {
    const seen: string[][] = []
    const transport = withCli(() => ({ code: 0, stdout: '/p\n', stderr: '' }), seen)
    await saveSetting(transport, 'SYNAPSE_VAULT_DIR', '/a vault')
    await clearSetting(transport, 'SYNAPSE_VAULT_DIR')
    expect(seen).toEqual([
      ['config', 'set', 'SYNAPSE_VAULT_DIR', '/a vault'],
      ['config', 'unset', 'SYNAPSE_VAULT_DIR'],
    ])
  })

  it('throws the reason when the program refuses the value', async () => {
    const refuse = withCli(() => ({
      code: 1,
      stdout: '',
      stderr: 'synapse-config: SYNAPSE_VAULT_PUSH_EVERY takes a whole number of at most 9 digits\n',
    }))
    await expect(saveSetting(refuse, 'SYNAPSE_VAULT_PUSH_EVERY', 'many')).rejects.toThrow(
      /takes a whole number/,
    )
  })
})

describe('helpers', () => {
  it('splits and joins a list setting', () => {
    expect(listItems('git, other ,')).toEqual(['git', 'other'])
    expect(listItems(null)).toEqual([])
    expect(joinItems(['git', 'other'])).toBe('git,other')
  })

  it('knows a whole number as the program does', () => {
    expect(isWholeNumber('0')).toBe(true)
    expect(isWholeNumber('123456789')).toBe(true)
    for (const text of ['', '1234567890', '1.5', '-1', 'a']) expect(isWholeNumber(text)).toBe(false)
  })
})

describe('groups', () => {
  const keys = [
    'SYNAPSE_VAULT_DIR',
    'SYNAPSE_VAULT_INTEGRATIONS',
    'SYNAPSE_GRAMMARS_DIR',
    'SYNAPSE_GRAMMARS_QUERY_PATH',
    'SYNAPSE_GRAMMAR_LOCK_TRIES',
    'SYNAPSE_VAULT_PUSH_EVERY',
    'SYNAPSE_AUTHOR_POOL',
    'SYNAPSE_DOCSTRING_STALENESS_DETECTION',
  ]
  const settings = keys.map((key) => ({ key }) as never)

  it('put the settings of the vault on its page and the rest with the code graph', () => {
    expect(settingsOf(settings, 'vault').map((s) => s.key)).toEqual([
      'SYNAPSE_VAULT_INTEGRATIONS',
      'SYNAPSE_VAULT_PUSH_EVERY',
    ])
    expect(settingsOf(settings, 'graph').map((s) => s.key)).toEqual([
      'SYNAPSE_GRAMMARS_DIR',
      'SYNAPSE_GRAMMARS_QUERY_PATH',
      'SYNAPSE_GRAMMAR_LOCK_TRIES',
      'SYNAPSE_AUTHOR_POOL',
      'SYNAPSE_DOCSTRING_STALENESS_DETECTION',
    ])
  })

  it('leave the vault itself to its card, and give every setting a page', () => {
    for (const group of ['vault', 'graph'] as const) {
      expect(settingsOf(settings, group).map((s) => s.key)).not.toContain('SYNAPSE_VAULT_DIR')
    }
    const shown = [...settingsOf(settings, 'vault'), ...settingsOf(settings, 'graph')]
    expect(shown).toHaveLength(keys.length - 1)
    expect(groupOf('A_SETTING_THAT_IS_NEW')).toBe('graph')
  })
})
