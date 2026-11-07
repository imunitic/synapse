import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { openSection, resetWorldSettings, world } from './helpers.ts'

// Each test begins from the settings the world began with.
test.beforeEach(() => {
  resetWorldSettings()
})

async function openSettings(page: import('@playwright/test').Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.getByRole('button', { name: 'All settings' }).click()
  await expect(page.getByRole('heading', { name: 'Synapse settings' })).toBeVisible()
}

test('a setting is written into synapse.conf when it is left, and reset removes it', async ({
  page,
}) => {
  await openSettings(page)
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
  await openSettings(page)
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
  await openSettings(page)
  const card = page.getByLabel('Vault', { exact: true })
  await card.getByRole('textbox').fill(world().vault)
  // Three notes: the folders that start with a dot hold none.
  await expect(card).toContainText('A folder with 3 notes, has an Index.md, is a git repository')

  await card.getByRole('button', { name: 'Use this vault' }).click()
  await expect(card.getByRole('button', { name: world().vault })).toBeVisible()
  expect(readFileSync(world().conf, 'utf8')).toContain(`SYNAPSE_VAULT_DIR=${world().vault}`)
})

test('a variable set in the app shows over the file in the settings', async ({ page }) => {
  await openSettings(page)
  const card = page.getByLabel('Environment')
  await card.getByRole('textbox', { name: 'Variable name' }).fill('SYNAPSE_GRAMMAR_LOCK_TRIES')
  await card.getByRole('textbox', { name: 'Variable value' }).fill('12')
  await card.getByRole('button', { name: 'Set' }).click()
  await expect(page.getByText('12 from the environment')).toBeVisible()

  await card.getByRole('button', { name: 'Remove' }).click()
  await expect(page.getByText('300, the default')).toBeVisible()

  await card.getByRole('textbox', { name: 'Variable name' }).fill('BAD NAME')
  await card.getByRole('button', { name: 'Set' }).click()
  await expect(card.getByRole('alert')).toContainText('A variable name has letters')
})
