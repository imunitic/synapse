import { mkdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { DatabaseSync } from 'node:sqlite'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { launchCard, openLaunch, world } from './helpers.ts'

const folder = (name: string) => join(world().root, 'workspaces', name)

const jsonl = (...records: unknown[]) => records.map((r) => JSON.stringify(r)).join('\n') + '\n'

// A session file of Claude Code that says it was held in a folder, and was last used `daysAgo`.
function claudeSession(id: string, cwd: string, title: string, daysAgo: number) {
  const dir = join(world().home, '.claude', 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'))
  mkdirSync(dir, { recursive: true })
  const file = join(dir, `${id}.jsonl`)
  writeFileSync(file, jsonl({ type: 'user', cwd }, { type: 'ai-title', aiTitle: title }))
  const when = new Date(Date.now() - daysAgo * 86_400_000)
  utimesSync(file, when, when)
}

// A rollout file of Codex.
function codexSession(id: string, cwd: string, prompt: string) {
  const dir = join(world().home, '.codex', 'sessions', '2026', '11', '08')
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, `rollout-2026-11-08T10-00-00-${id}.jsonl`),
    jsonl(
      { type: 'session_meta', payload: { id, cwd } },
      {
        type: 'response_item',
        payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: prompt }] },
      },
    ),
  )
}

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
  // What an earlier test of the world left.
  rmSync(join(home, '.claude', 'projects'), { recursive: true, force: true })
  for (let i = 1; i <= 7; i++) {
    claudeSession(`claude-s${i}`, folder(i % 2 === 0 ? 'alpha' : 'beta'), `Claude work ${i}`, i)
  }
  codexSession('codex-s1', folder('gamma'), 'Review the design')
  const data = join(world().data, 'opencode')
  mkdirSync(data, { recursive: true })
  const db = new DatabaseSync(join(data, 'opencode.db'))
  db.exec(
    'create table session_v2 (id text primary key, parent_id text, directory text not null, title text, time_updated integer not null)',
  )
  const add = db.prepare('insert into session_v2 values (?, ?, ?, ?, ?)')
  add.run('ses_one', null, folder('alpha'), 'Tidy the OpenCode notes', 5000)
  add.run('ses_child', 'ses_one', folder('alpha'), 'A child session', 9000)
  db.close()
})

test.afterEach(() => {
  const { home } = world()
  rmSync(join(home, '.claude.json'), { force: true })
  rmSync(join(home, '.claude', 'projects'), { recursive: true, force: true })
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
  await expect(claude.locator('.workspace')).toHaveCount(2)
  await expect(claude.locator('.workspace').nth(0)).toContainText('beta')
  await expect(claude.locator('.workspace').nth(0)).toContainText('1 minute ago')
  await expect(claude.locator('.workspace').nth(1)).toContainText('alpha')
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

// The list of a card that is shown by its tab.
async function showSessions(page: Page, name: 'Claude Code' | 'Codex' | 'OpenCode') {
  await launchCard(page, name)
    .getByRole('tab', { name: /^Sessions/ })
    .click()
}

test('each card has two lists in tabs, the folders first, with how many each has', async ({
  page,
}) => {
  await open(page)
  const claude = launchCard(page, 'Claude Code')
  await expect(claude.getByRole('tab', { name: 'Folders 2' })).toHaveAttribute(
    'aria-selected',
    'true',
  )
  await expect(claude.getByRole('tab', { name: 'Sessions 7' })).toHaveAttribute(
    'aria-selected',
    'false',
  )
  // Only the list that is chosen is there.
  await expect(claude.locator('.workspace')).toHaveCount(2)
  await expect(claude.locator('.past-session')).toHaveCount(0)
  await expect(claude.getByLabel('Another folder')).toBeVisible()

  await showSessions(page, 'Claude Code')
  await expect(claude.getByRole('tab', { name: /^Sessions/ })).toHaveAttribute(
    'aria-selected',
    'true',
  )
  await expect(claude.locator('.workspace')).toHaveCount(0)
  await expect(claude.getByLabel('Another folder')).toHaveCount(0)
})

test('past sessions are listed under each harness, the newest first, all of them', async ({
  page,
}) => {
  await open(page)
  await showSessions(page, 'Claude Code')
  const rows = launchCard(page, 'Claude Code').locator('.past-session')
  await expect(rows).toHaveCount(7)
  await expect(rows.nth(0)).toContainText('Claude work 1')
  await expect(rows.nth(0)).toContainText('beta')
  await expect(rows.nth(0)).toContainText('1 day ago')
  await expect(rows.nth(6)).toContainText('Claude work 7')

  await showSessions(page, 'Codex')
  await expect(launchCard(page, 'Codex').locator('.past-session')).toContainText(
    'Review the design',
  )
  await showSessions(page, 'OpenCode')
  const opencode = launchCard(page, 'OpenCode').locator('.past-session')
  await expect(opencode).toHaveCount(1)
  await expect(opencode).toContainText('Tidy the OpenCode notes')
})

test('a card opens on the list it showed last, for each harness on its own', async ({ page }) => {
  await open(page)
  await showSessions(page, 'Codex')
  await page.reload()
  await openLaunch(page)
  await expect(launchCard(page, 'Codex').getByRole('tab', { name: /^Sessions/ })).toHaveAttribute(
    'aria-selected',
    'true',
  )
  await expect(
    launchCard(page, 'Claude Code').getByRole('tab', { name: /^Folders/ }),
  ).toHaveAttribute('aria-selected', 'true')
  await launchCard(page, 'Codex')
    .getByRole('tab', { name: /^Folders/ })
    .click()
  await page.reload()
  await openLaunch(page)
  await expect(launchCard(page, 'Codex').getByRole('tab', { name: /^Folders/ })).toHaveAttribute(
    'aria-selected',
    'true',
  )
})

test('resuming a Claude session continues it in the folder it was held in', async ({ page }) => {
  await open(page)
  await showSessions(page, 'Claude Code')
  await launchCard(page, 'Claude Code')
    .getByRole('button', { name: 'Resume Claude Code session Claude work 2' })
    .click()
  const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toBeVisible()
  await expect(terminal).toContainText('--resume claude-s2')
  await expect(terminal).not.toContainText('--session-id')
  await expect(terminal).toContainText(`cwd: ${folder('alpha')}`)
})

test('resuming a Codex session and an OpenCode session uses their own commands', async ({
  page,
}) => {
  await open(page)
  await showSessions(page, 'Codex')
  await launchCard(page, 'Codex')
    .getByRole('button', { name: 'Resume Codex session Review the design' })
    .click()
  const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await expect(terminal).toContainText('resume codex-s1')
  await expect(terminal).toContainText(`cwd: ${folder('gamma')}`)

  await page.getByRole('tab', { name: 'New terminal' }).click()
  await showSessions(page, 'OpenCode')
  await launchCard(page, 'OpenCode')
    .getByRole('button', { name: 'Resume OpenCode session Tidy the OpenCode notes' })
    .click()
  await expect(terminal).toContainText('--session ses_one')
  await expect(terminal).toContainText(`cwd: ${folder('alpha')}`)
})

test('the two lists of a card are tabs, with the open one underlined', async ({ page }) => {
  await open(page)
  const tabs = launchCard(page, 'Claude Code').getByRole('tablist')
  await expect(tabs.getByRole('tab', { name: /^Folders/ })).toHaveAttribute('aria-selected', 'true')
  const colour = (selected: boolean) =>
    page.evaluate(
      `getComputedStyle(document.querySelector('section[aria-label="Claude Code"] .subtab[aria-selected=${selected}]')).borderBottomColor`,
    )
  const underlined = await colour(true)
  const other = await colour(false)
  expect(other).toBe('rgba(0, 0, 0, 0)')
  expect(underlined).not.toBe(other)
})
