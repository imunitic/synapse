// What a person types in the Run dialog, and what it becomes: the input of a run is any JSON
// value, handed to the first step as it is. Pure, so the dialog only has to show it.

import type { CliResult } from '../../shared/transport.ts'

// A sentence, which is sent as a JSON string, or JSON for a pipeline that expects an object.
export type InputMode = 'text' | 'json'

export type RunInput = { ok: true; value: unknown } | { ok: false; error: string }

// The input the text stands for. A text box with nothing in it is no input, which is not the
// same as an empty object or an empty string.
export function runInput(mode: InputMode, text: string, json: string): RunInput {
  if (mode === 'text') {
    return { ok: true, value: text.trim() === '' ? undefined : text.trim() }
  }
  try {
    return { ok: true, value: JSON.parse(json) as unknown }
  } catch (error) {
    return { ok: false, error: `The input is not valid JSON: ${String(error)}` }
  }
}

// The input as the prompt preview asks for it: JSON text, or nothing while there is none or
// while the JSON is not whole.
export function previewInput(mode: InputMode, text: string, json: string): string | undefined {
  const input = runInput(mode, text, json)
  if (!input.ok || input.value === undefined) return undefined
  return JSON.stringify(input.value)
}

// Why a pipeline cannot be run interactively, from what `check --interactive` said, or null
// when it can. The warnings it prints beside are not the reason.
export function interactiveProblem(result: CliResult): string | null {
  if (result.code === 0) return null
  const lines = result.stderr
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('warning:'))
  return lines.length > 0
    ? lines.map((line) => line.replace(/^error: /, '')).join(' ')
    : 'This pipeline cannot be run interactively.'
}

// The choice to run without a terminal is kept for each pipeline in the browser, and is off where
// nothing was kept or the storage cannot be used.
const choiceKey = (pipeline: string) => `run-autonomous:${pipeline}`

export function readAutonomous(storage: Pick<Storage, 'getItem'>, pipeline: string): boolean {
  try {
    return storage.getItem(choiceKey(pipeline)) === '1'
  } catch {
    return false
  }
}

export function writeAutonomous(
  storage: Pick<Storage, 'setItem' | 'removeItem'>,
  pipeline: string,
  on: boolean,
): void {
  try {
    if (on) storage.setItem(choiceKey(pipeline), '1')
    else storage.removeItem(choiceKey(pipeline))
  } catch {
    // The choice is only a convenience.
  }
}

// The folder an interactive run works in is kept for each pipeline too, and is the default folder
// of the terminals where none was kept.
const folderKey = (pipeline: string) => `run-folder:${pipeline}`

export function readFolder(
  storage: Pick<Storage, 'getItem'>,
  pipeline: string,
  fallback: string,
): string {
  try {
    return storage.getItem(folderKey(pipeline)) ?? fallback
  } catch {
    return fallback
  }
}

export function writeFolder(
  storage: Pick<Storage, 'setItem' | 'removeItem'>,
  pipeline: string,
  folder: string,
): void {
  try {
    if (folder.trim() === '') storage.removeItem(folderKey(pipeline))
    else storage.setItem(folderKey(pipeline), folder.trim())
  } catch {
    // The folder is only a convenience.
  }
}
