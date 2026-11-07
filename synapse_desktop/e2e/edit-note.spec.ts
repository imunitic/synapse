import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

const TARGET =
  '---\ntitle: Target\nupdated: 2026-01-01T00:00:00+00:00\n---\n# Target\n\nFirst line.\n'
const OTHER =
  '---\ntitle: Other\nupdated: 2026-01-01T00:00:00+00:00\n---\n# Other\n\nAnother note.\n'

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'edit-note-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  mkdirSync(join(vault, 'synapse', 'widget@main'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(join(vault, 'research', 'Target.md'), TARGET)
  writeFileSync(join(vault, 'research', 'Other.md'), OTHER)
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Node.md'),
    '---\ntitle: Node\n---\nA node.\n',
  )
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

async function openTarget(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'research' }).click()
  await panel.getByRole('button', { name: 'Target' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Target' })).toBeVisible()
}

async function change(page: Page, description: string) {
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  await page.getByLabel('What should change?').fill(description)
  await page.getByRole('button', { name: 'Change the note' }).click()
}

test('a note has a pencil that opens a box to describe the change, and a node of a code graph has none', async ({
  page,
}) => {
  await openTarget(page)
  const pencil = page.getByRole('button', { name: 'Edit with an agent' })
  await expect(pencil).toBeVisible()
  await pencil.click()
  await expect(page.getByLabel('What should change?')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Change the note' })).toBeDisabled()
  await expect(page.getByText('It is told to change only this note.')).toBeVisible()
  await pencil.click()
  await expect(page.getByLabel('What should change?')).toHaveCount(0)

  // A node of a code graph is opened from the graph, and is not for an agent to change.
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await page.evaluate(() => undefined)
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'synapse' }).click()
  await panel.getByRole('button', { name: 'widget@main' }).click()
  await panel.getByRole('button', { name: 'Node' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Node' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Edit with an agent' })).toHaveCount(0)
})

test('the box opens under the title, and Cancel closes it and forgets what was typed', async ({
  page,
}) => {
  await openTarget(page)
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  const box = page.getByRole('region', { name: 'Change this note with an agent' })
  await expect(box).toBeVisible()
  const title = await page.getByRole('heading', { level: 1, name: 'Target' }).boundingBox()
  const opened = await box.boundingBox()
  // Under the title and not beside it.
  expect(opened!.y).toBeGreaterThanOrEqual(title!.y + title!.height - 1)

  await page.getByLabel('What should change?').fill('Something I then think better of')
  await box.getByRole('button', { name: 'Cancel' }).click()
  await expect(box).toHaveCount(0)
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  await expect(page.getByLabel('What should change?')).toHaveValue('')
})

test('the agent changes the note, which is read again, and what it did is shown', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line about the change')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed: 2 lines added and 0 removed.')
  await expect(page.locator('.note-body')).toContainText('Stub edit: Add a line about the change')
  // The box closes and is empty for the next change.
  await expect(page.getByLabel('What should change?')).toHaveCount(0)

  await result.getByText('Show what changed').click()
  const diff = result.getByLabel('The lines that changed')
  await expect(diff).toContainText('+ Stub edit: Add a line about the change')
  await expect(result).not.toContainText('also moved')
})

test('undo puts the note back as it was', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line to undo')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toContain('Stub edit')

  await result.getByRole('button', { name: 'Undo' }).click()
  await expect(result).toContainText('The note is put back as it was.')
  await expect(result.getByRole('button', { name: 'Undo' })).toHaveCount(0)
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
  await expect(page.getByText('Stub edit')).toHaveCount(0)
})

test('undo is refused, and nothing is written, when the note was changed again', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  const changedByHand = `${readFileSync(join(vault, 'research', 'Target.md'), 'utf8')}\nA line by hand.\n`
  writeFileSync(join(vault, 'research', 'Target.md'), changedByHand)

  await result.getByRole('button', { name: 'Undo' }).click()
  await expect(result.getByRole('alert')).toContainText('The note was changed again since')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(changedByHand)
  // It can be tried again, since the note is still as the change left it, apart from the line.
  await expect(result.getByRole('button', { name: 'Undo' })).toBeEnabled()
})

test('says so when another note moved, which the agent was told not to touch', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line and TOUCHOTHER')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result.getByRole('alert')).toContainText('research/Other.md')
  await expect(result.getByRole('alert')).toContainText('which it was told not to')
})

test('says why when the note was not changed, and keeps the box and what was typed', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'FAILCASE please')
  await expect(page.getByRole('alert')).toContainText('The note was not changed.')
  await expect(page.getByRole('alert')).toContainText('the stub was asked to fail')
  await expect(page.getByLabel('What should change?')).toHaveValue('FAILCASE please')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)

  await page.getByLabel('What should change?').fill('NOCHANGE')
  await page.getByRole('button', { name: 'Change the note' }).click()
  await expect(page.getByRole('alert')).toContainText('The note was not changed.')
})
