import { expect, test } from './fixtures.ts'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { resetWorldSettings, world } from './helpers.ts'

test.beforeEach(() => {
  resetWorldSettings()
})

test.afterEach(() => {
  resetWorldSettings()
})

// A vault in the world, which is the vault until the settings are put back.
function useVault(name: string, notes: Record<string, string>): string {
  const vault = join(world().root, name)
  for (const [path, text] of Object.entries(notes)) {
    mkdirSync(join(vault, path, '..'), { recursive: true })
    writeFileSync(join(vault, path), text)
  }
  mkdirSync(vault, { recursive: true })
  const before = readFileSync(world().conf, 'utf8')
  writeFileSync(world().conf, `${before}SYNAPSE_VAULT_DIR=${vault}\n`)
  return vault
}

test('the vault page says what needs a decision, and a click opens the note', async ({ page }) => {
  const vault = useVault('status-vault', {
    'designs/p/Talk.md': '---\ntitle: Talk\nnote_id: p-1\n---\n## Status\nDiscussing\n',
    'tasks/p/Work.md':
      '---\ntitle: Work\ntask_id: p-2\nstatus: IN-PROGRESS\n---\n- [ ] one\n- [ ] two\n',
  })
  try {
    await page.goto('/')
    // The vault's button in the rail shows its panel and opens the status page.
    await page.getByRole('button', { name: 'Vault', exact: true }).first().click()
    await expect(page.getByRole('tab', { name: 'Vault', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    )
    // Design notes and task notes are apart, each under its own heading.
    const designs = page.getByLabel('Design notes', { exact: true })
    const tasks = page.getByLabel('Task notes', { exact: true })
    await expect(designs.getByLabel('Discussing', { exact: true })).toContainText('p-1')
    await expect(designs).not.toContainText('p-2')
    await expect(tasks.getByLabel('In progress (unchecked items)')).toContainText('p-2')
    await expect(tasks).not.toContainText('p-1')
    const discussing = page.getByLabel('Discussing', { exact: true })
    await expect(discussing).toContainText('p-1')
    await expect(discussing).toContainText('Talk')
    const progress = page.getByLabel('In progress (unchecked items)')
    await expect(progress).toContainText('p-2')
    await expect(progress).toContainText('2 unchecked')
    await expect(page.getByText(vault)).toBeVisible()

    await discussing.getByRole('button', { name: /Talk/ }).click()
    await expect(page.getByRole('tab', { name: 'Talk' })).toBeVisible()

    // A page that is not the status page is left alone by a second click, which hides the panel,
    // and the Status entry of the panel leads back.
    await page.getByRole('button', { name: 'Vault', exact: true }).first().click()
    await expect(page.getByRole('tab', { name: 'Talk' })).toHaveAttribute('aria-selected', 'true')
    await page.getByRole('button', { name: 'Vault', exact: true }).first().click()
    await page.getByRole('button', { name: /Status\s+What needs a decision/ }).click()
    await expect(page.getByRole('tab', { name: 'Vault', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    )
  } finally {
    rmSync(vault, { recursive: true, force: true })
  }
})

test('the vault page says so when nothing needs a decision, and Home leads to it', async ({
  page,
}) => {
  const vault = useVault('clear-vault', { 'research/Note.md': '---\ntitle: Note\n---\nText\n' })
  try {
    await page.goto('/')
    await page
      .getByRole('region', { name: 'Vault', exact: true })
      .getByRole('button', { name: 'Open the status' })
      .click()
    await expect(page.getByText('Vault is clear')).toBeVisible()
    await expect(
      page.getByRole('heading', { level: 1, name: 'What needs a decision' }),
    ).toBeVisible()
  } finally {
    rmSync(vault, { recursive: true, force: true })
  }
})
