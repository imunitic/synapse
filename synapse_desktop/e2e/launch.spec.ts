import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { DatabaseSync } from 'node:sqlite'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { launchCard, openLaunch, world } from './helpers.ts'

const folder = (name: string) => join(world().root, 'workspaces', name)

// What the harnesses remember of the folders they work in, as they keep it.
test.beforeEach(() => {
  for (const name of ['alpha', 'beta', 'gamma']) mkdirSync(folder(name), { recursive: true })
  const { home } = world()
  mkdirSync(join(home, '.codex'), { recursive: true })
  writeFileSync(
    join(home, '.claude.json'),
    JSON.stringify({
      oauthAccount: { emailAddress: 'someone@example.com' },
      projects: {
        [folder('alpha')]: { hasTrustDialogAccepted: true, lastSessionModified: 1000 },
        [folder('beta')]: {
          hasTrustDialogAccepted: true,
          lastSessionModified: Date.now() - 60_000,
        },
        [folder('gamma')]: { hasTrustDialogAccepted: false },
        [join(world().root, 'workspaces', 'deleted')]: { hasTrustDialogAccepted: true },
      },
    }),
  )
  writeFileSync(
    join(home, '.codex', 'config.toml'),
    `[projects."${folder('gamma')}"]\ntrust_level = "trusted"\n`,
  )
  const data = join(world().data, 'opencode')
  mkdirSync(data, { recursive: true })
  const db = new DatabaseSync(join(data, 'opencode.db'))
  db.exec(
    'create table session_v2 (id text primary key, parent_id text, directory text not null, time_updated integer not null)',
  )
  db.prepare('insert into session_v2 values (?, ?, ?, ?)').run('s1', null, folder('alpha'), 5000)
  db.close()
})

test.afterEach(() => {
  const { home } = world()
  rmSync(join(home, '.claude.json'), { force: true })
  rmSync(join(home, '.codex'), { recursive: true, force: true })
  rmSync(join(world().data, 'opencode'), { recursive: true, force: true })
  rmSync(join(world().root, 'workspaces'), { recursive: true, force: true })
})

async function open(page: Page) {
  await page.goto('/')
  await openLaunch(page)
}

test('the rail opens it as a page of its own, in a tab', async ({ page }) => {
  await open(page)
  await expect(page.getByRole('button', { name: 'Terminals', exact: true })).toHaveAttribute(
    'aria-pressed',
    'true',
  )
  await expect(page.getByRole('tab', { name: 'New terminal' })).toBeVisible()
})

test('each harness lists the folders it already works in, the newest first', async ({ page }) => {
  await open(page)
  const claude = launchCard(page, 'Claude Code')
  // Allowed folders only: the one that is not allowed and the one that is gone are not there.
  await expect(claude.getByRole('button')).toHaveCount(3)
  await expect(claude.getByRole('button').nth(0)).toContainText('beta')
  await expect(claude.getByRole('button').nth(0)).toContainText('1 minute ago')
  await expect(claude.getByRole('button').nth(1)).toContainText('alpha')
  await expect(claude).not.toContainText('gamma')
  await expect(claude).not.toContainText('deleted')

  await expect(launchCard(page, 'Codex').getByRole('button', { name: /gamma/ })).toBeVisible()
  await expect(launchCard(page, 'OpenCode').getByRole('button', { name: /alpha/ })).toBeVisible()
})

test('nothing of the rest of a harness file reaches the page', async ({ page }) => {
  await open(page)
  await expect(page.getByText('someone@example.com')).toHaveCount(0)
})

test('a harness is started in a folder with one click, with no home folder in between', async ({
  page,
}) => {
  await open(page)
  await launchCard(page, 'Claude Code').getByRole('button', { name: /beta/ }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toBeVisible()
  await expect(page.locator('.terminal-view:not([hidden]) .terminal-host')).toContainText(
    `cwd: ${folder('beta')}`,
  )
})

test('another folder can be typed, and an empty one cannot be started', async ({ page }) => {
  await open(page)
  const codex = launchCard(page, 'Codex')
  await expect(codex.getByRole('button', { name: 'Start' })).toBeDisabled()
  await codex.getByLabel('Another folder').fill(folder('alpha'))
  await codex.getByRole('button', { name: 'Start' }).click()
  await expect(page.getByRole('tab', { name: 'Codex 1' })).toBeVisible()
})

test('a shell still starts in the folder of the settings, or the home folder', async ({ page }) => {
  await open(page)
  await expect(page.getByLabel('Start in')).toHaveValue('')
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
})

test('the launch tab stays beside the tab of the sessions', async ({ page }) => {
  await open(page)
  await launchCard(page, 'OpenCode').getByRole('button', { name: /alpha/ }).click()
  await expect(page.getByRole('tab', { name: 'Terminals' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'New terminal' })).toBeVisible()
})
