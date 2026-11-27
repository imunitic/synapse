// Asking the program about a draft that is not saved.

import { randomBytes } from 'node:crypto'
import { defaultConfig } from '../shared/calls.ts'
import type { CliResult, DraftDefinition } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { loadConfig } from './config-store.ts'
import { definitionDirs, pipelineConfigDir, type Environment } from './roots.ts'
import { buildSandbox } from './sandbox.ts'

export interface PreviewDeps {
  environment: Environment
  configFile: string
  runCli: CliRunner
}

// A pipeline is described. A system, an agent or a prompt cannot be, so the
// program is asked to check a pipeline that uses none of them: it loads every definition, and
// says in a warning what is wrong with one that does not load.
export async function previewDraft(draft: DraftDefinition, deps: PreviewDeps): Promise<CliResult> {
  const config = await loadConfig(deps.configFile, deps.environment)
  const defaultDir = pipelineConfigDir(deps.environment)
  const otherDirs = definitionDirs(config, deps.environment).filter((d) => d !== defaultDir)

  const probe = draft.kind === 'pipeline' ? null : `Draft_Probe_${randomBytes(3).toString('hex')}`
  const box = await buildSandbox({
    defaultDir,
    otherDirs,
    draft: { name: draft.name, text: draft.text },
    extra:
      probe === null
        ? undefined
        : {
            name: probe,
            text: `Pipeline ${probe} { Only [Harness => Claude, Prompt => "probe"]; }`,
          },
  })
  try {
    return await deps.runCli({
      binary: 'synapse-pipeline',
      args: probe === null ? ['show', draft.name, '--format', 'json'] : ['check', probe],
      // Nothing of the real configuration: the copy is the whole world.
      config: defaultConfig,
      env: box.env,
    })
  } finally {
    await box.cleanup()
  }
}
