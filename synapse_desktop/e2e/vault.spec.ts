import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'notes-vault')
  mkdirSync(join(vault, 'designs', 'p'), { recursive: true })
  mkdirSync(join(vault, 'tasks', 'p'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n\nThe start.\n')
  writeFileSync(
    join(vault, 'designs', 'p', 'Talk.md'),
    [
      '---',
      'title: Talk',
      'note_id: p-1',
      'tags: [alpha, beta]',
      '---',
      '# Talk',
      '',
      '## Status',
      'Discussing',
      '',
      'It links to [[Work]], to [[Nope]] and to <https://example.com/page>.',
      '',
      '| a | b |',
      '|---|---|',
      '| 1 | 2 |',
      '',
      '- [ ] an open item',
      '',
      '```',
      '[[Kept]]',
      '```',
      '',
    ].join('\n'),
  )
  writeFileSync(
    join(vault, 'tasks', 'p', 'Work.md'),
    '---\ntitle: Work\ntask_id: p-2\nstatus: IN-PROGRESS\n---\nBack to [[Talk]].\n\n- [ ] one\n',
  )
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

async function openVault(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
}

test('the notes are a tree of folders that open, and a note opens from it', async ({ page }) => {
  await openVault(page)
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await expect(tree.getByRole('button', { name: 'Index' })).toBeVisible()
  // Folders are closed until opened.
  await expect(tree.getByRole('button', { name: 'Talk' })).toHaveCount(0)
  await tree.getByRole('button', { name: /designs/ }).click()
  await tree.getByRole('button', { name: 'p', exact: true }).click()
  await tree.getByRole('button', { name: 'Talk' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Talk' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Talk' })).toHaveAttribute('aria-selected', 'true')
})

test('a note shows its properties and its text', async ({ page }) => {
  await openVault(page)
  await sidePanel(page).getByRole('searchbox', { name: 'Search the notes' }).fill('Discussing')
  await page.keyboard.press('Enter')
  await sidePanel(page).getByLabel('Search results').getByRole('button', { name: /Talk/ }).click()

  const props = page.getByLabel('Properties')
  await expect(props).toContainText('note_id')
  await expect(props).toContainText('p-1')
  await expect(props.getByText('alpha', { exact: true })).toBeVisible()
  await expect(props.getByText('beta', { exact: true })).toBeVisible()
  // The table, the task list and the code are rendered, and not their text.
  await expect(page.getByRole('table')).toContainText('1')
  await expect(page.getByRole('checkbox')).toBeVisible()
  await expect(page.locator('pre')).toContainText('[[Kept]]')
  await expect(page.getByRole('link', { name: 'https://example.com/page' })).toHaveAttribute(
    'target',
    '_blank',
  )
})

test('a link between notes opens the note, a missing one is not a link, and the backlinks are listed', async ({
  page,
}) => {
  await openVault(page)
  await sidePanel(page).getByRole('searchbox', { name: 'Search the notes' }).fill('Discussing')
  await page.keyboard.press('Enter')
  await sidePanel(page).getByLabel('Search results').getByRole('button', { name: /Talk/ }).click()

  const body = page.locator('.note-body')
  await expect(body.getByRole('link', { name: 'Nope' })).toHaveCount(0)
  await expect(body.getByText('Nope')).toBeVisible()
  await body.getByRole('link', { name: 'Work' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Work' })).toBeVisible()
  await expect(page.getByLabel('Properties')).toContainText('IN-PROGRESS')

  // Work links back to Talk, and Talk links to Work.
  await expect(page.getByLabel('Linked from')).toContainText('Talk')
  await page.getByLabel('Links').getByRole('button', { name: /Talk/ }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Talk' })).toBeVisible()
})

test('a search says when no note has the words', async ({ page }) => {
  await openVault(page)
  await sidePanel(page).getByRole('searchbox', { name: 'Search the notes' }).fill('zzzzqqqq')
  await page.keyboard.press('Enter')
  await expect(sidePanel(page)).toContainText('No note has those words.')
})

test('the vault items on the home page open their notes', async ({ page }) => {
  await page.goto('/')
  const attention = page.getByLabel('Needs attention')
  await attention.getByRole('button', { name: /Talk/ }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Talk' })).toBeVisible()
})
