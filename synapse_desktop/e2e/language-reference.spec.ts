import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { DSL_SHAPES } from '../web/domain/dsl-reference.ts'
import { openSection, setEditorText, sidePanel, uniqueName } from './helpers.ts'

type Kind = 'pipeline' | 'system' | 'agent'

const KINDS: { kind: Kind; plural: string }[] = [
  { kind: 'pipeline', plural: 'Pipelines' },
  { kind: 'system', plural: 'Systems' },
  { kind: 'agent', plural: 'Agents' },
]

async function openNew(page: Page, kind: string, plural: string) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: plural, exact: true }).click()
  await sidePanel(page)
    .getByRole('button', { name: `New ${kind}` })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: `New ${kind}` })).toBeVisible()
}

const card = (page: Page) => page.locator('details.dsl-reference')

test('the reference is closed until it is opened, and then has a shape, attributes and rules', async ({
  page,
}) => {
  await openNew(page, 'pipeline', 'Pipelines')
  await expect(card(page)).toHaveCount(1)
  await expect(card(page)).not.toHaveAttribute('open', '')
  await expect(card(page).locator('summary')).toContainText('Language reference')

  await card(page).locator('summary').click()
  await expect(card(page).getByLabel('A pipeline')).toContainText('Pipeline Name {')
  const table = card(page).getByRole('table', { name: 'Attributes' })
  await expect(table.getByRole('row', { name: /^When/ })).toContainText('outcome name or JSON')
  await expect(table.getByRole('row', { name: /^Max_Iterations/ })).toContainText('integer')
  await expect(card(page).getByText('An edge back to an earlier step')).toBeVisible()
})

test('shows the attributes of the kind that is written, and no others', async ({ page }) => {
  await openNew(page, 'agent', 'Agents')
  await card(page).locator('summary').click()
  const names = card(page).getByRole('table', { name: 'Attributes' }).getByRole('rowheader')
  await expect(names).toHaveText(['Prompt', 'Skill'])

  await openNew(page, 'system', 'Systems')
  await card(page).locator('summary').click()
  const system = card(page).getByRole('table', { name: 'Attributes' }).getByRole('rowheader')
  await expect(system.filter({ hasText: /^Permissions$/ })).toHaveCount(1)
  await expect(system.filter({ hasText: /^System$/ })).toHaveCount(0)
  await expect(system.filter({ hasText: /^When$/ })).toHaveCount(0)
})

test('is not shown for a skill, which is not written in the language', async ({ page }) => {
  await openNew(page, 'skill', 'Skills')
  await expect(card(page)).toHaveCount(0)
})

for (const { kind, plural } of KINDS) {
  test(`the example of a ${kind} is accepted by the checker as it is shown`, async ({ page }) => {
    await openNew(page, kind, plural)
    await card(page).locator('summary').click()
    const example = (await card(page).locator('pre.dsl-shape').textContent()) ?? ''
    expect(example).not.toBe('')
    // Its name is the only thing a person changes.
    const text = example.replace('Name', uniqueName('Example'))
    // The checker is shown to be working before the example is put to it: broken text raises the
    // problems, and the example clears them, so that "None." is the answer to the example and not
    // what the page says before it has been asked.
    await setEditorText(page, `${text}\n@@@`)
    const broken = page.getByRole('alert', { name: 'Problems' })
    await expect(broken).toContainText('To fix before it can be created')
    await setEditorText(page, text)
    await expect(broken).toHaveCount(0)
    await expect(page.getByLabel('Problems')).toContainText('None.')
    await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeEnabled()
  })
}

// The editor sees the syntax of a system or an agent that stands alone, and the attributes of
// either only when a pipeline uses it. So the examples are put to the checker together, as a
// pipeline built from the other two.
test('the three examples work together, as the checker reads a pipeline built from them', () => {
  const dir = mkdtempSync(join(tmpdir(), 'synapse-dsl-'))
  try {
    const files: Record<string, string> = {
      Shape_Pipeline: DSL_SHAPES.pipeline.replace('Name', 'Shape_Pipeline'),
      Shape_System: DSL_SHAPES.system.replace('Name', 'Shape_System'),
      Shape_Agent: DSL_SHAPES.agent.replace('Name', 'Shape_Agent'),
      Uses_Both: 'Pipeline Uses_Both { Only [Agent => Shape_Agent, System => Shape_System]; }',
    }
    for (const [name, text] of Object.entries(files))
      writeFileSync(join(dir, `${name}.synapse`), text)
    const check = (pipeline: string) =>
      spawnSync('synapse-pipeline', ['check', pipeline], {
        encoding: 'utf8',
        env: { ...process.env, SYNAPSE_PIPELINE_PATH: dir, XDG_CONFIG_HOME: join(dir, 'xdg') },
      })
    for (const pipeline of ['Shape_Pipeline', 'Uses_Both']) {
      const result = check(pipeline)
      expect(`${pipeline}: ${result.stderr}`).not.toMatch(/error:/)
      expect(result.status).toBe(0)
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
