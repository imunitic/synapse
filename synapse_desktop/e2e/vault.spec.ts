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
      `updated: ${new Date().toISOString()}`,
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
    `---\ntitle: Work\ntask_id: p-2\nstatus: IN-PROGRESS\nupdated: ${new Date(Date.now() - 2 * 3_600_000).toISOString()}\n---\nBack to [[Talk]].\n\n- [ ] one\n`,
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

  // A note is as wide as the other pages of text.
  await page.locator('.page.note').waitFor()
  const widths = await page.evaluate(`(() => {
    const probe = document.createElement('div')
    probe.className = 'page'
    document.body.append(probe)
    const plain = getComputedStyle(probe).maxWidth
    probe.remove()
    return { plain, note: getComputedStyle(document.querySelector('.page.note')).maxWidth }
  })()`)
  expect(widths).toEqual({
    plain: expect.stringMatching(/px$/),
    note: (widths as { plain: string }).plain,
  })

  // A line says what the note is, and the properties are there when they are opened.
  const props = page.getByLabel('Properties')
  await expect(props.locator('summary')).toContainText('p-1')
  await expect(props.locator('summary').getByText('alpha', { exact: true })).toBeVisible()
  await expect(props.locator('summary').getByText('beta', { exact: true })).toBeVisible()
  await expect(props.locator('dl')).toBeHidden()
  await props.locator('summary').click()
  await expect(props.locator('dl')).toContainText('note_id')
  await expect(props.locator('dl')).toContainText('p-1')
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
  await expect(page.getByLabel('Properties').locator('summary')).toContainText('IN-PROGRESS')

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

test('the home page offers the notes updated lately, newest first, and the notes opened', async ({
  page,
}) => {
  await page.goto('/')
  const next = page.getByLabel('Continue')
  const updated = next.locator('.attention-group').filter({ hasText: 'Updated lately' })
  const rows = updated.getByRole('button')
  await expect(rows).toHaveCount(2)
  await expect(rows.nth(0)).toContainText('Talk')
  await expect(rows.nth(0)).toContainText('just now')
  await expect(rows.nth(1)).toContainText('Work')
  await expect(rows.nth(1)).toContainText('2 hours ago')
  // Nothing has been opened yet.
  await expect(next).not.toContainText('Opened lately')

  await rows.nth(1).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Work' })).toBeVisible()
  await page.getByRole('button', { name: 'Home', exact: true }).click()
  const opened = page
    .getByLabel('Continue')
    .locator('.attention-group')
    .filter({ hasText: 'Opened lately' })
  await expect(opened.getByRole('button')).toHaveCount(1)
  await expect(opened).toContainText('Work')
  await expect(opened).toContainText('tasks/p/Work.md')
  await opened.getByRole('button', { name: /Work/ }).click()
  await expect(page.getByRole('tab', { name: 'Work' })).toHaveAttribute('aria-selected', 'true')
})

test('with no vault there is nothing to continue from', async ({ page }) => {
  resetWorldSettings()
  await page.goto('/')
  await expect(page.getByLabel('Needs attention')).toBeVisible()
  await expect(page.getByLabel('Continue')).toHaveCount(0)
})

test('the side panel is on the vault again when a note is the page that shows', async ({
  page,
}) => {
  await openVault(page)
  await sidePanel(page)
    .getByLabel('Notes', { exact: true })
    .getByRole('button', { name: 'Index' })
    .click()
  await expect(page.getByRole('tab', { name: 'Index' })).toHaveAttribute('aria-selected', 'true')

  await openSection(page, 'Definitions')
  await expect(
    sidePanel(page).getByRole('heading', { level: 2, name: 'Definitions' }),
  ).toBeVisible()
  // Another page, and then the note again: the panel goes with the page that comes to show.
  await page.getByRole('tab', { name: 'Home', exact: true }).click()
  await expect(
    sidePanel(page).getByRole('heading', { level: 2, name: 'Definitions' }),
  ).toBeVisible()
  await page.getByRole('tab', { name: 'Index', exact: true }).click()
  await expect(sidePanel(page).getByRole('heading', { level: 2, name: 'Vault' })).toBeVisible()
})
