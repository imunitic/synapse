import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { openLaunch, openSection, resetWorldSettings, world } from './helpers.ts'

// Each test begins from the settings the world began with.
test.beforeEach(() => {
  resetWorldSettings()
})

type Page = import('@playwright/test').Page

async function openSettings(page: Page, category: string) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await openCategory(page, category)
}

async function openCategory(page: Page, category: string) {
  // The item whose label is the category, not one whose line about it names the category.
  const item = page.locator('.settings-item').filter({ hasText: new RegExp(`^${category}`) })
  if (!(await item.isVisible())) await openSection(page, 'Settings')
  await item.click()
  await expect(page.getByRole('heading', { level: 1, name: category })).toBeVisible()
}

test('a setting is written into synapse.conf when it is left, and reset removes it', async ({
  page,
}) => {
  await openSettings(page, 'Vault')
  const row = page.getByLabel('SYNAPSE_VAULT_PUSH_EVERY')
  await expect(row).toHaveValue('7')

  await row.fill('4')
  await row.press('Enter')
  await expect(page.getByText('4 from the file')).toBeVisible()
  expect(readFileSync(world().conf, 'utf8')).toContain('SYNAPSE_VAULT_PUSH_EVERY=4')
  // The comment line of the file is as it was.
  expect(readFileSync(world().conf, 'utf8')).toContain('# the settings of the tests')

  await page.getByRole('button', { name: 'Reset' }).first().click()
  await expect(page.getByText('5, the default')).toBeVisible()
  expect(readFileSync(world().conf, 'utf8')).not.toContain('SYNAPSE_VAULT_PUSH_EVERY')
})

test('a value that does not fit is refused with the reason, and Escape puts back the file', async ({
  page,
}) => {
  await openSettings(page, 'Vault')
  const row = page.getByLabel('SYNAPSE_VAULT_PUSH_EVERY')
  const before = readFileSync(world().conf, 'utf8')

  await row.fill('many')
  await row.press('Tab')
  await expect(page.getByRole('alert').filter({ hasText: 'takes a whole number' })).toBeVisible()
  expect(readFileSync(world().conf, 'utf8')).toBe(before)

  await row.focus()
  await row.press('Escape')
  await expect(page.getByRole('alert').filter({ hasText: 'takes a whole number' })).toHaveCount(0)
  await expect(row).not.toHaveValue('many')
})

test('the vault is switched to a folder that looks like one', async ({ page }) => {
  await openSettings(page, 'Vault')
  const card = page.getByRole('region', { name: 'Vault folder', exact: true })
  await card.getByRole('textbox').fill(world().vault)
  // Three notes: the folders that start with a dot hold none.
  await expect(card).toContainText('A folder with 3 notes, has an Index.md, is a git repository')

  await card.getByRole('button', { name: 'Use this vault' }).click()
  await expect(card.getByRole('button', { name: world().vault })).toBeVisible()
  expect(readFileSync(world().conf, 'utf8')).toContain(`SYNAPSE_VAULT_DIR=${world().vault}`)
})

test('a variable set in the app shows over the file in the settings', async ({ page }) => {
  await openSettings(page, 'Environment')
  const card = page.getByLabel('Environment', { exact: true })
  await card.getByRole('textbox', { name: 'Variable name' }).fill('SYNAPSE_GRAMMAR_LOCK_TRIES')
  await card.getByRole('textbox', { name: 'Variable value' }).fill('12')
  await card.getByRole('button', { name: 'Set' }).click()
  await openCategory(page, 'Code graph')
  await expect(page.getByText('12 from the environment')).toBeVisible()

  await openCategory(page, 'Environment')
  await card.getByRole('button', { name: 'Remove' }).click()
  await openCategory(page, 'Code graph')
  await expect(page.getByText('300, the default')).toBeVisible()

  await openCategory(page, 'Environment')
  await card.getByRole('textbox', { name: 'Variable name' }).fill('BAD NAME')
  await card.getByRole('button', { name: 'Set' }).click()
  await expect(card.getByRole('alert')).toContainText('A variable name has letters')
})

test('the general page keeps the work directory, the default harness and extra folders', async ({
  page,
}) => {
  await openSettings(page, 'General')
  await page.getByRole('combobox', { name: 'Default harness' }).selectOption('Codex')
  await expect(page.getByRole('combobox', { name: 'Default harness' })).toHaveValue('Codex')

  const folders = page.getByLabel('Definition folders')
  await folders.getByRole('textbox', { name: 'Folder to add' }).fill('relative/path')
  await folders.getByRole('button', { name: 'Add' }).click()
  await expect(folders.getByRole('alert')).toContainText('must be absolute')

  await folders.getByRole('textbox', { name: 'Folder to add' }).fill(world().root)
  await folders.getByRole('button', { name: 'Add' }).click()
  await expect(folders.getByText(world().root)).toBeVisible()
  await folders.getByRole('button', { name: 'Remove' }).click()
  await expect(folders.getByText('None are added.')).toBeVisible()
})

test('a terminal starts in the folder the settings name', async ({ page }) => {
  await openSettings(page, 'Terminals')
  await page.getByLabel('Start folder path').fill(world().root)
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByRole('status')).toHaveText('Saved.')
  await openLaunch(page)
  await expect(page.getByLabel('Start in')).toHaveValue(world().root)
})

test('the environment page lists the variables Synapse reads with their defaults', async ({
  page,
}) => {
  await openSettings(page, 'Environment')
  const known = page.getByLabel('Variables Synapse reads')
  const row = known.locator('li').filter({ hasText: 'SYNAPSE_GRAMMAR_LOCK_TRIES' })
  await expect(row).toContainText('Default 300')

  await row.getByRole('button', { name: 'Use' }).click()
  const card = page.getByLabel('Environment', { exact: true })
  await expect(card.getByRole('textbox', { name: 'Variable name' })).toHaveValue(
    'SYNAPSE_GRAMMAR_LOCK_TRIES',
  )
  await expect(card.getByRole('textbox', { name: 'Variable value' })).toHaveValue('300')
  await card.getByRole('textbox', { name: 'Variable value' }).fill('9')
  await card.getByRole('button', { name: 'Set' }).click()
  await expect(row).toContainText('now from the environment: 9')
})
