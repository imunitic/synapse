// The settings of `synapse.conf`, as `synapse config list --format json` gives
// them, and the calls that change one.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'

const settingSchema = z.object({
  key: z.string(),
  kind: z.enum(['path', 'list', 'number', 'toggle']),
  description: z.string(),
  default: z.string().nullable(),
  required: z.boolean(),
  // A variable of the same name can set it.
  environment: z.boolean(),
  // What is in force.
  value: z.string().nullable(),
  source: z.enum(['environment', 'file', 'default', 'unset']),
  // The file that defines it and what it says there, as written.
  file: z.string().nullable(),
  file_value: z.string().nullable(),
  shadowed: z.boolean(),
})

const listSchema = z.object({
  format: z.literal('synapse-config/v1'),
  conf: z.object({ read: z.string().nullable(), write: z.string().nullable() }),
  settings: z.array(settingSchema),
})

export type SynapseSetting = z.infer<typeof settingSchema>

export interface SynapseSettings {
  // The file read, and the one a new setting is written to.
  read: string | null
  write: string | null
  settings: SynapseSetting[]
}

async function config(transport: Transport, args: string[]): Promise<string> {
  const result = await transport.cli('synapse', ['config', ...args])
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() === '' ? `config ${args[0]} failed` : result.stderr.trim())
  }
  return result.stdout
}

// Throws when `synapse` cannot be run or answers in a form this app does not
// know.
export async function loadSettings(transport: Transport): Promise<SynapseSettings> {
  const text = await config(transport, ['list', '--format', 'json'])
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    throw new Error('config list did not answer JSON')
  }
  const parsed = listSchema.safeParse(json)
  if (!parsed.success) throw new Error('config list answered a form this app does not know')
  return {
    read: parsed.data.conf.read,
    write: parsed.data.conf.write,
    settings: parsed.data.settings,
  }
}

// Writes the setting into the file that holds it. Throws with the program's own
// reason when the value does not fit.
export async function saveSetting(transport: Transport, key: string, value: string): Promise<void> {
  await config(transport, ['set', key, value])
}

// Removes the setting from its file, so that it is what it is when nothing sets it.
export async function clearSetting(transport: Transport, key: string): Promise<void> {
  await config(transport, ['unset', key])
}

// The names in a list setting, in order.
export function listItems(value: string | null): string[] {
  return (value ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item !== '')
}

// The value of a list setting made of these names.
export function joinItems(items: readonly string[]): string {
  return items.join(',')
}

// What the program would answer to a value for a number setting, so that a
// form can say so before asking.
export function isWholeNumber(text: string): boolean {
  return /^[0-9]{1,9}$/.test(text)
}
