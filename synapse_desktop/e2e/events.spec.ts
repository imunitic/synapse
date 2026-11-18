import { expect, test } from './fixtures.ts'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

test.beforeEach(() => {
  resetWorldSettings()
})

test.afterEach(() => {
  resetWorldSettings()
})

test('a run record that appears on disk shows in the executions without a refresh', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Executions')
  await expect(sidePanel(page).getByText('exec-watched')).toHaveCount(0)

  const dir = join(world().work, 'pipelines', 'exec-watched')
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'execution.json'),
    JSON.stringify({
      format: 'synapse-pipeline-execution/v1',
      id: 'exec-watched',
      pipeline: 'Develop_Feature',
      started: new Date().toISOString(),
      ended: new Date().toISOString(),
      status: 'completed',
      current_step: null,
      state: { steps_run: 1 },
    }),
  )
  try {
    // Well before the slow look the list makes anyway.
    await expect(sidePanel(page).getByText('Develop_Feature')).toBeVisible({ timeout: 5000 })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a note changed on disk shows on its page without a refresh', async ({ page }) => {
  const vault = join(world().root, 'watched-vault')
  mkdirSync(vault, { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n\nThe start.\n')
  writeFileSync(join(vault, 'Note.md'), '---\ntitle: Note\n---\nBefore the change.\n')
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
  try {
    await page.goto('/')
    await openSection(page, 'Vault')
    await sidePanel(page)
      .getByLabel('Notes', { exact: true })
      .getByRole('button', { name: 'Note' })
      .click()
    await expect(page.locator('.note-body')).toContainText('Before the change.')

    writeFileSync(join(vault, 'Note.md'), '---\ntitle: Note\n---\nAfter the change.\n')
    await expect(page.locator('.note-body')).toContainText('After the change.', { timeout: 5000 })
  } finally {
    rmSync(vault, { recursive: true, force: true })
  }
})
