import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'refresh-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  mkdirSync(join(vault, 'designs', 'p'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(join(vault, 'research', 'First.md'), '---\ntitle: First\n---\nThe first text.\n')
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  rmSync(join(world().definitions, 'Later_Agent.synapse'), { force: true })
  resetWorldSettings()
})

async function openVault(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  await expect(sidePanel(page).getByLabel('Notes', { exact: true })).toBeVisible()
}

test('the refresh of the vault panel shows a note that was added after it was read', async ({
  page,
}) => {
  await openVault(page)
  writeFileSync(join(vault, 'research', 'Added later.md'), '---\ntitle: Added later\n---\nx\n')
  await sidePanel(page).getByRole('button', { name: 'Refresh the notes' }).click()
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await tree.getByRole('button', { name: /research/ }).click()
  await expect(tree.getByRole('button', { name: 'Added later' })).toBeVisible()
})

test('the refresh of the definitions panel shows a definition that was added after it was read', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Agents', exact: true }).click()
  await expect(sidePanel(page).getByRole('button', { name: 'Developer' })).toBeVisible()
  writeFileSync(
    join(world().definitions, 'Later_Agent.synapse'),
    'Agent Later_Agent [Prompt => "Added later."];\n',
  )
  await expect(sidePanel(page).getByRole('button', { name: 'Later_Agent' })).toHaveCount(0)
  await sidePanel(page).getByRole('button', { name: 'Refresh the lists' }).click()
  await expect(sidePanel(page).getByRole('button', { name: 'Later_Agent' })).toBeVisible()
})

test('the refresh of the home page shows a note that needs attention, added after it was read', async ({
  page,
}) => {
  await page.goto('/')
  const attention = page.getByLabel('Needs attention')
  await expect(attention.getByText('Nothing needs attention.')).toBeVisible()
  writeFileSync(
    join(vault, 'designs', 'p', 'Later design.md'),
    '---\nschema: vault-design-note/v1\ntitle: Later design\nproject: p\nnote_id: p-1\ntags: []\n---\n# Later design\n\n## Status\nDiscussing\n',
  )
  await attention.getByRole('button', { name: 'Refresh' }).click()
  await expect(attention).toContainText('Later design')
})

test('a note that was changed on disk is read again beside the pencil, with what it links to', async ({
  page,
}) => {
  writeFileSync(join(vault, 'research', 'Second.md'), '---\ntitle: Second\n---\nThe second.\n')
  await openVault(page)
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await tree.getByRole('button', { name: /research/ }).click()
  await tree.getByRole('button', { name: 'First' }).click()
  await expect(page.getByText('The first text.')).toBeVisible()
  await expect(page.getByLabel('Links')).toHaveCount(0)

  // Another program changes the note: the page does not know until it is told to read it again.
  writeFileSync(
    join(vault, 'research', 'First.md'),
    '---\ntitle: First\n---\nThe changed text, and a link to [[Second]].\n',
  )
  await expect(page.getByText('The first text.')).toBeVisible()
  await page.getByRole('button', { name: 'Read the note again' }).click()
  await expect(page.getByText(/The changed text/)).toBeVisible()
  await expect(page.getByText('The first text.')).toHaveCount(0)
  await expect(page.getByLabel('Links').getByRole('button', { name: /Second/ })).toBeVisible()
})

test('the button to read a note again is beside the pencil', async ({ page }) => {
  await openVault(page)
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await tree.getByRole('button', { name: /research/ }).click()
  await tree.getByRole('button', { name: 'First' }).click()
  const refresh = page.getByRole('button', { name: 'Read the note again' })
  const pencil = page.getByRole('button', { name: 'Edit with an agent' })
  const a = (await refresh.boundingBox())!
  const b = (await pencil.boundingBox())!
  expect(a.x + a.width).toBeLessThanOrEqual(b.x + 1)
  expect(Math.abs(a.y - b.y)).toBeLessThanOrEqual(2)
})

test('a node of a code graph, which has no pencil, can be read again as well', async ({ page }) => {
  mkdirSync(join(vault, 'synapse', 'widget@main'), { recursive: true })
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Node.md'),
    '---\ntitle: Node\n---\nThe first node text.\n',
  )
  await openVault(page)
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await tree.getByRole('button', { name: /synapse/ }).click()
  await tree.getByRole('button', { name: /widget@main/ }).click()
  await tree.getByRole('button', { name: 'Node' }).click()
  await expect(page.getByText('The first node text.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Edit with an agent' })).toHaveCount(0)

  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Node.md'),
    '---\ntitle: Node\n---\nThe second node text.\n',
  )
  await page.getByRole('button', { name: 'Read the note again' }).click()
  await expect(page.getByText('The second node text.')).toBeVisible()
})
