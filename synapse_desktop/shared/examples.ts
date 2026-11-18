/// <reference types="vite/client" />
// The example files of the messages, read as data. They are files so that the tests of the Rust host
// read the same ones.

import type { MessageName } from './messages.ts'

export interface Example {
  name: MessageName
  params: unknown
  result: unknown
}

const files = import.meta.glob<Example>('./examples/*.json', {
  eager: true,
  import: 'default',
})

const envelopeFiles = import.meta.glob<Record<string, unknown>>('./examples/_envelope.json', {
  eager: true,
  import: 'default',
})

export const examples: Example[] = Object.entries(files)
  .filter(([path]) => !path.includes('/_'))
  .map(([, example]) => example)

export const envelopeExamples: Record<string, unknown> = Object.values(envelopeFiles)[0] ?? {}
