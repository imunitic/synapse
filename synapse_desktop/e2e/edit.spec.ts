import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test } from '@playwright/test'
import { openSection, setEditorText, uniqueName, world } from './helpers.ts'

async function openDefinition(page: import('@playwright/test').Page, name: string) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: new RegExp(name) })
    .click()
  await expect(page.getByRole('heading', { name })).toBeVisible()
}

test('an existing definition is edited in place, keeping its name', async ({ page }) => {
  const name = uniqueName('Edited')
  const file = join(world().definitions, `${name}.synapse`)
  writeFileSync(file, `Pipeline ${name} { Only [Harness => Claude, Prompt => "One."]; }\n`)
  await openDefinition(page, name)

  await page.getByRole('button', { name: 'Edit', exact: true }).click()
  const save = page.getByRole('button', { name: 'Save', exact: true })
  await expect(save).toBeDisabled()

  // The name cannot change.
  await setEditorText(page, `Pipeline Renamed { Only [Harness => Claude, Prompt => "One."]; }`)
  await expect(page.getByLabel('Problems')).toContainText(`The name of this file is ${name}`)
  await expect(save).toBeDisabled()

  await setEditorText(
    page,
    `Pipeline ${name} { Only [Harness => Claude, Prompt => "One."]; Then [Harness => Codex, Prompt => "Two."]; }`,
  )
  await expect(page.getByLabel('Diagram').getByLabel('Step Then, Codex')).toBeVisible()
  await save.click()

  // The page is read again.
  await expect(page.getByRole('button', { name: 'Edit', exact: true })).toBeVisible()
  await expect(page.getByLabel('Step Then, Codex')).toBeVisible()
  expect(readFileSync(file, 'utf8')).toContain('Then [Harness => Codex')
})

test('a save is refused when the file has changed since it was read', async ({ page }) => {
  const name = uniqueName('Conflict')
  const file = join(world().definitions, `${name}.synapse`)
  writeFileSync(file, `Pipeline ${name} { Only [Harness => Claude, Prompt => "One."]; }\n`)
  await openDefinition(page, name)
  await page.getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeDisabled()

  const elsewhere = `Pipeline ${name} { Other [Harness => Claude, Prompt => "Changed elsewhere."]; }\n`
  writeFileSync(file, elsewhere)
  await setEditorText(page, `Pipeline ${name} { Mine [Harness => Claude, Prompt => "Mine."]; }`)
  await expect(page.getByLabel('Problems')).toContainText('None.')
  await page.getByRole('button', { name: 'Save', exact: true }).click()

  await expect(page.getByText('the file has changed since it was read')).toBeVisible()
  expect(readFileSync(file, 'utf8')).toBe(elsewhere)
})
