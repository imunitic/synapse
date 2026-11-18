import { describe, expect, it } from 'vitest'
import type { CliResult } from '../../shared/transport.ts'
import {
  declaredOf,
  isDefinitionName,
  isSkillName,
  marksFor,
  readPreview,
  renameDeclared,
  renameSkill,
  skillProblems,
  templateFor,
} from './drafts.ts'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import { parseProblems } from './pipelines.ts'

describe('declaredOf', () => {
  it('reads the kind and the name from the first two words', () => {
    expect(declaredOf('Pipeline Dev {}')).toEqual({ kind: 'pipeline', name: 'Dev' })
    expect(declaredOf('System Strict_Reviewer [Agent => A];')).toEqual({
      kind: 'system',
      name: 'Strict_Reviewer',
    })
    expect(declaredOf('Agent  Reviewer\n[Prompt => "x"];')).toEqual({
      kind: 'agent',
      name: 'Reviewer',
    })
  })

  it('skips comments and blank lines before them', () => {
    expect(declaredOf('-- one\n\n  -- two\nPipeline P {')).toEqual({ kind: 'pipeline', name: 'P' })
  })

  it('finds nothing without both words, or with another kind', () => {
    for (const text of [
      '',
      'Pipeline',
      'Pipeline {',
      'Widget Thing {}',
      'pipeline p {}',
      'Pipeline 1x {}',
    ]) {
      expect(declaredOf(text)).toBeNull()
    }
  })
})

describe('templates', () => {
  it('declare what they are for, so that a new page starts valid in shape', () => {
    expect(declaredOf(templateFor('pipeline'))).toEqual({ kind: 'pipeline', name: 'New_Pipeline' })
    expect(declaredOf(templateFor('system'))).toEqual({ kind: 'system', name: 'New_System' })
    expect(declaredOf(templateFor('agent'))).toEqual({ kind: 'agent', name: 'New_Agent' })
    expect(skillProblems(templateFor('skill'))).toEqual([])
  })
})

describe('readPreview', () => {
  const ok: CliResult = { code: 0, stdout: DEVELOP_FEATURE_SHOW, stderr: '' }

  it('gives the description of a pipeline that can run', () => {
    const preview = readPreview({ kind: 'pipeline', name: 'Develop_Feature' }, ok)
    expect(preview.problems).toEqual([])
    expect(preview.description?.steps).toHaveLength(3)
  })

  it('gives every problem of a pipeline that cannot', () => {
    const preview = readPreview(
      { kind: 'pipeline', name: 'P' },
      {
        code: 1,
        stdout: '',
        stderr:
          "error: /s/xdg/synapse-pipeline/P.synapse:2:27: unknown attribute 'Harnes'\nerror: /s/xdg/synapse-pipeline/P.synapse:2:19: there is no agent named 'Nobody'\n",
      },
    )
    expect(preview.description).toBeNull()
    expect(preview.problems.map((p) => [p.line, p.column])).toEqual([
      [2, 27],
      [2, 19],
    ])
  })

  it('keeps of a checked pipeline only the warnings that name the draft', () => {
    const stderr =
      "warning: /s/xdg/synapse-pipeline/Fresh.synapse:1:30: expected a value after '=>', found ']'\n" +
      'warning: /s/xdg/synapse-pipeline/Broken_One.synapse:1:32: unknown attribute x\n'
    const preview = readPreview({ kind: 'agent', name: 'Fresh' }, { code: 0, stdout: '', stderr })
    expect(preview.description).toBeNull()
    expect(preview.problems).toHaveLength(1)
    expect(preview.problems[0]).toMatchObject({ severity: 'warning', line: 1, column: 30 })
  })

  it('finds nothing wrong with a system or an agent that loads', () => {
    expect(
      readPreview({ kind: 'system', name: 'S' }, { code: 0, stdout: 'pipeline X', stderr: '' })
        .problems,
    ).toEqual([])
  })
})

describe('marksFor', () => {
  const text = 'Pipeline P {\n  Build [Harnes => Claude];\n}\n'

  it('puts a problem on the word at its line and column', () => {
    const [mark] = marksFor(text, parseProblems('error: /f/P.synapse:2:10: unknown attribute x'))
    expect(text.slice(mark!.from, mark!.to)).toBe('Harnes')
    expect(mark).toMatchObject({ severity: 'error', message: 'unknown attribute x' })
  })

  it('runs to the end of the line when there is no word at the column', () => {
    const [mark] = marksFor(text, parseProblems('error: /f/P.synapse:2:17: odd'))
    expect(text.slice(mark!.from, mark!.to)).toBe('=> Claude];')
  })

  it('leaves out a problem with no place, or a place that is not in the text', () => {
    const marks = marksFor(text, [
      { severity: 'error', file: null, line: null, column: null, message: 'no place' },
      { severity: 'error', file: 'f', line: 99, column: 1, message: 'past the end' },
    ])
    expect(marks).toEqual([])
  })

  it('does not go past the end of the text', () => {
    const [mark] = marksFor('Agent A', parseProblems('error: /f/A.synapse:1:500: far'))
    expect(mark!.from).toBeLessThanOrEqual('Agent A'.length)
    expect(mark!.to).toBeLessThanOrEqual('Agent A'.length)
  })
})

describe('renaming', () => {
  it('changes the name a definition declares and nothing else', () => {
    const text = '-- a comment\nPipeline Old_Name {\n  Old_Name [Prompt => "x"];\n}\n'
    expect(renameDeclared(text, 'New_Name')).toBe(
      '-- a comment\nPipeline New_Name {\n  Old_Name [Prompt => "x"];\n}\n',
    )
    expect(renameDeclared('Agent  A [Prompt => "x"];', 'B')).toBe('Agent  B [Prompt => "x"];')
  })

  it('leaves a text that declares no name as it is', () => {
    expect(renameDeclared('nothing here', 'X')).toBe('nothing here')
    expect(renameDeclared('Pipeline {', 'X')).toBe('Pipeline {')
  })

  it('changes the name in the frontmatter of a skill and nothing else', () => {
    const text =
      '---\nname: old-name\ndescription: Does it. name: not this\n---\n\nname: nor this\n'
    expect(renameSkill(text, 'new-name')).toBe(
      '---\nname: new-name\ndescription: Does it. name: not this\n---\n\nname: nor this\n',
    )
  })

  it('leaves a skill with no name in its frontmatter as it is', () => {
    expect(renameSkill('---\ndescription: x\n---\n', 'n')).toBe('---\ndescription: x\n---\n')
    expect(renameSkill('no frontmatter', 'n')).toBe('no frontmatter')
  })

  it('knows a name a definition can have', () => {
    expect(isDefinitionName('Develop_Feature')).toBe(true)
    for (const name of ['', '1x', 'a b', 'a-b']) expect(isDefinitionName(name)).toBe(false)
  })
})

describe('skills', () => {
  it('knows the form of a skill name', () => {
    expect(isSkillName('review-code')).toBe(true)
    for (const name of ['', 'Upper', 'a--b', '-a', 'a-', 'a_b', 'a'.repeat(65)]) {
      expect(isSkillName(name)).toBe(false)
    }
  })

  it('wants a frontmatter with a good name and a description', () => {
    expect(skillProblems('---\nname: ok-name\ndescription: Does it.\n---\n')).toEqual([])
    expect(skillProblems('no frontmatter').map((p) => p.message)).toEqual([
      'the frontmatter has no name',
      'the frontmatter has no description',
    ])
    expect(skillProblems('---\nname: Bad Name\ndescription: x\n---\n')[0]?.message).toMatch(
      /lowercase/,
    )
  })
})
