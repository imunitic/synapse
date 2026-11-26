import { expect, test, type Page } from './fixtures.ts'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, sidePanel, world } from './helpers.ts'

// Opens the Clone dialog of Develop_Feature from its row in the pipelines list.
async function openClone(page: Page) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Pipelines' }).click()
  await sidePanel(page).getByRole('button', { name: 'Clone Develop_Feature', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Clone Develop_Feature' })
  await expect(dialog).toBeVisible()
  return dialog
}

test('a pipeline is cloned and its page opens', async ({ page }) => {
  const copy = join(world().definitions, 'Develop_Feature_Copy.synapse')
  try {
    const dialog = await openClone(page)
    await expect(dialog.getByLabel('Name')).toHaveValue('Develop_Feature_Copy')
    await dialog.getByRole('button', { name: 'Clone', exact: true }).click()

    await expect(
      page.getByRole('heading', { level: 1, name: 'Develop_Feature_Copy' }),
    ).toBeVisible()
    const panel = sidePanel(page)
    await expect(panel.getByRole('button', { name: 'Develop_Feature', exact: true })).toBeVisible()
    await expect(
      panel.getByRole('button', { name: 'Develop_Feature_Copy', exact: true }),
    ).toBeVisible()
    expect(readFileSync(copy, 'utf8')).toContain('Pipeline Develop_Feature_Copy {')
  } finally {
    rmSync(copy, { force: true })
  }
})

test('a taken name is refused before anything is written', async ({ page }) => {
  const dialog = await openClone(page)
  await dialog.getByLabel('Name').fill('Reviewer')
  await expect(dialog.getByRole('alert')).toHaveText('An agent called Reviewer already exists.')
  await expect(dialog.getByRole('button', { name: 'Clone', exact: true })).toBeDisabled()
  expect(existsSync(join(world().definitions, 'Reviewer.synapse'))).toBe(true)
})

test('a name the schema refuses is explained', async ({ page }) => {
  const dialog = await openClone(page)
  await dialog.getByLabel('Name').fill('1bad')
  await expect(dialog.getByRole('alert')).toContainText('starts with a letter')
  await expect(dialog.getByRole('button', { name: 'Clone', exact: true })).toBeDisabled()
  expect(existsSync(join(world().definitions, '1bad.synapse'))).toBe(false)
})
