import { describe, expect, it } from 'vitest'
import { fakeTransport } from './fake-transport.ts'
import { listSkillFiles, parseSkillMeta } from './skills.ts'

describe('parseSkillMeta', () => {
  it('reads the name and the description of the frontmatter', () => {
    const text = '---\nname: review-code\ndescription: Review a change for problems.\n---\n\nBody.'
    expect(parseSkillMeta(text)).toEqual({
      name: 'review-code',
      description: 'Review a change for problems.',
    })
  })

  it('drops quotes around a value and ignores other keys', () => {
    const text = '---\nname: "x"\nlicense: MIT\ndescription: \'Does x.\'\n---\n'
    expect(parseSkillMeta(text)).toEqual({ name: 'x', description: 'Does x.' })
  })

  it('gives nothing without a frontmatter block, and does not read the body', () => {
    expect(parseSkillMeta('Just text.\nname: nope')).toEqual({ name: null, description: null })
    expect(parseSkillMeta('---\nname: a\n---\ndescription: in the body')).toEqual({
      name: 'a',
      description: null,
    })
  })

  it('gives nothing for a value that is empty', () => {
    expect(parseSkillMeta('---\nname:\n---').name).toBeNull()
  })
})

describe('listSkillFiles', () => {
  it('lists what the skill directory holds, directories with a slash', async () => {
    const transport = fakeTransport({
      paths: { definitionDirs: [], skillsDir: '/s', recordsDir: null },
      files: {
        '/s/x/SKILL.md': 'a',
        '/s/x/notes.md': 'b',
        '/s/x/scripts/run.sh': 'c',
        '/s/y/SKILL.md': 'other skill',
      },
    })
    expect(await listSkillFiles(transport, '/s/x/SKILL.md')).toEqual([
      'notes.md',
      'scripts/',
      'SKILL.md',
    ])
  })
})
