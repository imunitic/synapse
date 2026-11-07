import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'new-note-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

async function openNewNote(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'New note' })).toBeVisible()
}

test('the + of the vault opens a page that asks which kind of note and what it says', async ({
  page,
}) => {
  await openNewNote(page)
  const write = page.getByRole('button', { name: 'Write the note' })
  await expect(write).toBeDisabled()
  const kinds = page.getByRole('group', { name: 'Kind of note' })
  await expect(kinds.getByRole('button', { name: 'Note', exact: true })).toHaveAttribute(
    'aria-pressed',
    'true',
  )
  await kinds.getByRole('button', { name: 'Task note' }).click()
  await expect(kinds.getByRole('button', { name: 'Task note' })).toHaveAttribute(
    'aria-pressed',
    'true',
  )
  await expect(page.getByText('A tracked task, with a status and a checklist.')).toBeVisible()
  await page.getByLabel('Describe the note').fill('Ship the thing')
  await expect(write).toBeEnabled()
})

test('the agent writes the kind of note that was chosen, and the note opens', async ({ page }) => {
  await openNewNote(page)
  await page
    .getByRole('group', { name: 'Kind of note' })
    .getByRole('button', { name: 'Design note' })
    .click()
  await page.getByLabel('Describe the note').fill('Why keys are per branch')
  await page.getByRole('button', { name: 'Write the note' }).click()

  // The page is replaced by the note the agent wrote, which is in the tree.
  await expect(page.getByRole('tab', { name: /Stub note/ })).toBeVisible()
  await expect(page.getByRole('heading', { level: 1, name: 'Stub note' })).toBeVisible()
  // The stub puts the prompt it was given in the note.
  await expect(page.getByText('synapse-design-note skill')).toBeVisible()
  await expect(page.getByText('Why keys are per branch')).toBeVisible()
  await expect(sidePanel(page).getByRole('button', { name: 'research' })).toBeVisible()
})

// The harness the app keeps as the default, which is what writes a note.
function useDefaultHarness(harness: string) {
  const file = join(world().xdg, 'synapse-desktop', 'config.json')
  const stored = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>
  writeFileSync(file, JSON.stringify({ ...stored, defaultHarness: harness }))
}

for (const [harness, program, label] of [
  ['Claude', 'claude', 'Claude Code'],
  ['Codex', 'codex', 'Codex'],
  ['Opencode', 'opencode', 'OpenCode'],
] as const) {
  test(`the default harness, ${label}, is the one that writes the note`, async ({ page }) => {
    useDefaultHarness(harness)
    await openNewNote(page)
    await expect(page.getByText(`${label} writes it with Synapse`)).toBeVisible()
    await page.getByLabel('Describe the note').fill('Whatever it is')
    await page.getByRole('button', { name: 'Write the note' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Stub note' })).toBeVisible()
    await expect(page.getByText(`Written by ${program}`)).toBeVisible()
  })
}

test('says why when the agent could not write the note, and keeps what was typed', async ({
  page,
}) => {
  await openNewNote(page)
  await page.getByLabel('Describe the note').fill('FAILCASE please')
  await page.getByRole('button', { name: 'Write the note' }).click()
  await expect(page.getByRole('alert')).toContainText('No note was written.')
  await expect(page.getByRole('alert')).toContainText('the stub was asked to fail')
  await expect(page.getByLabel('Describe the note')).toHaveValue('FAILCASE please')
  await expect(page.getByRole('button', { name: 'Write the note' })).toBeEnabled()
})
