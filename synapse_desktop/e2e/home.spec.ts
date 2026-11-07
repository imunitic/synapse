import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { resetWorldSettings, world } from './helpers.ts'

test.beforeEach(() => {
  resetWorldSettings()
})

test.afterEach(() => {
  resetWorldSettings()
})

const card = (page: Page) => page.getByLabel('Needs attention')

test('the app opens on the home page, and the rail leads back to it', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Home' })).toHaveAttribute('aria-selected', 'true')

  await page.getByRole('button', { name: 'Settings', exact: true }).click()
  await page.locator('.settings-item').filter({ hasText: 'General' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()

  await page.getByRole('button', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Home' })).toHaveAttribute('aria-selected', 'true')
})

test('a missing vault is listed and leads to the page that sets it', async ({ page }) => {
  await page.goto('/')
  await expect(card(page)).toContainText('No vault is configured')
  await card(page)
    .getByRole('button', { name: /No vault is configured/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'Vault' })).toBeVisible()
})

test('a run that failed lately is listed with why, and opens', async ({ page }) => {
  const id = 'exec-home-1'
  const dir = join(world().work, 'pipelines', id)
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'execution.json'),
    JSON.stringify({
      format: 'synapse-pipeline-execution/v1',
      id,
      pipeline: 'Ship_Release',
      started: new Date().toISOString(),
      ended: new Date().toISOString(),
      status: 'failed',
      current_step: null,
      state: { steps_run: 1, failure: { step: 'Build', message: 'the build exited with 1' } },
    }),
  )
  try {
    await page.goto('/')
    const item = card(page).getByRole('button', { name: /Ship_Release failed/ })
    await expect(item).toContainText('Build: the build exited with 1')
    await item.click()
    await expect(page.getByRole('tab', { name: id })).toBeVisible()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the vault says what needs a decision', async ({ page }) => {
  const vault = join(world().root, 'attention-vault')
  mkdirSync(join(vault, 'designs', 'p'), { recursive: true })
  mkdirSync(join(vault, 'tasks', 'p'), { recursive: true })
  writeFileSync(
    join(vault, 'designs', 'p', 'Talk.md'),
    '---\ntitle: Talk\nnote_id: p-1\n---\n## Status\nDiscussing\n',
  )
  writeFileSync(
    join(vault, 'tasks', 'p', 'Work.md'),
    '---\ntitle: Work\ntask_id: p-2\nstatus: IN-PROGRESS\n---\n- [ ] one\n- [ ] two\n',
  )
  const before = readFileSync(world().conf, 'utf8')
  writeFileSync(world().conf, `${before}SYNAPSE_VAULT_DIR=${vault}\n`)
  try {
    await page.goto('/')
    await expect(card(page)).toContainText('Discussing')
    await expect(card(page)).toContainText('[p-1] Talk')
    await expect(card(page)).toContainText('In progress (unchecked items)')
    await expect(card(page)).toContainText('[p-2] Work')
    await expect(card(page)).toContainText('2 unchecked')
    await expect(card(page)).not.toContainText('No vault is configured')
  } finally {
    rmSync(vault, { recursive: true, force: true })
  }
})
