import { expect, test } from '@playwright/test'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, world } from './helpers.ts'

// What a test leaves in the harnesses' folders would show in the terminal tests.
test.afterEach(() => {
  for (const folder of [['.claude'], ['.codex'], ['.config', 'opencode']]) {
    rmSync(join(world().home, ...folder), { recursive: true, force: true })
  }
})

async function openIntegrations(page: import('@playwright/test').Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'Integrations' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Integrations' })).toBeVisible()
}

test('each harness is listed with what it has, and the app says which Synapse it has', async ({
  page,
}) => {
  await openIntegrations(page)
  const mine = page.getByLabel("This app's Synapse")
  await expect(mine).toContainText('Version')
  await expect(mine).toContainText('synapse-hook')
  for (const name of ['Claude Code', 'Codex', 'OpenCode']) {
    const card = page.getByLabel(name, { exact: true })
    await expect(card).toContainText('Not installed')
    await expect(card.getByRole('button', { name: 'Install' })).toBeEnabled()
  }
})

const INSTALL =
  'npm install -g @imunitic/synapse@latest @imunitic/synapse-pipeline@latest && synapse-setup configure claude && synapse-pipeline-setup configure claude'

// The terminal of the tab that is showing.
const screen = (page: import('@playwright/test').Page) =>
  page.locator('.terminal-view:not([hidden]) .terminal-host')

test('installing asks first, naming the command and what it writes', async ({ page }) => {
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await card.getByRole('button', { name: 'Install' }).click()
  const question = card.getByRole('alertdialog')
  await expect(question).toContainText('Are you sure?')
  await expect(question).toContainText('opens a terminal tab')
  await expect(question).toContainText(INSTALL)
  await expect(question).toContainText('settings.json.bak')
  // Nothing has been opened, or written.
  await expect(page.getByRole('tab', { name: /Install Claude Code/ })).toHaveCount(0)
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
})

test('saying yes opens a shell tab that runs the npm install, and writes nothing itself', async ({
  page,
}) => {
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await card.getByRole('button', { name: 'Install' }).click()
  await card.getByRole('button', { name: 'Yes, install' }).click()

  await expect(page.getByRole('tab', { name: 'Install Claude Code' })).toBeVisible()
  // What was typed is on the screen, and it was run: npm's own words are there as well.
  await expect(screen(page)).toContainText('npm install -g @imunitic/synapse@latest')
  await expect(screen(page)).toContainText('synapse-pipeline-setup configure claude')
  await expect(screen(page)).toContainText(/ENOTCACHED|npm error/)
  // The app wrote nothing into the harness, and no other harness was touched.
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
  expect(existsSync(join(world().home, '.codex'))).toBe(false)
})

test('each harness gets its own command, and the tab says what it is for', async ({ page }) => {
  await openIntegrations(page)
  await page.getByLabel('Codex', { exact: true }).getByRole('button', { name: 'Install' }).click()
  await expect(page.getByLabel('Codex', { exact: true }).getByRole('alertdialog')).toContainText(
    'synapse-setup configure codex && synapse-pipeline-setup configure codex',
  )
  await page
    .getByLabel('Codex', { exact: true })
    .getByRole('button', { name: 'Yes, install' })
    .click()
  await expect(page.getByRole('tab', { name: 'Install Codex' })).toBeVisible()
  await expect(screen(page)).toContainText('synapse-setup configure codex')
})

test('a hook program that is gone is shown, and repairing runs the same command', async ({
  page,
}) => {
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  const settings = JSON.stringify({
    theme: 'dark',
    hooks: {
      SessionStart: [
        { hooks: [{ type: 'command', command: '/gone/bin/synapse-hook session-start' }] },
      ],
    },
  })
  writeFileSync(join(world().home, '.claude', 'settings.json'), settings)
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await expect(card).toContainText('Its hook program is missing')
  await card.getByRole('button', { name: 'Repair' }).click()
  await card.getByRole('button', { name: 'Yes, repair' }).click()
  await expect(page.getByRole('tab', { name: 'Repair Claude Code' })).toBeVisible()
  await expect(screen(page)).toContainText('synapse-setup configure claude')
  // The file is the person's, and the app left it as it was.
  expect(readFileSync(join(world().home, '.claude', 'settings.json'), 'utf8')).toBe(settings)
})

// A package of another version of Synapse, whose hook a harness is told to run.
function packageOf(version: string): string {
  const pkg = join(world().root, `package-${version}`)
  mkdirSync(join(pkg, 'bin'), { recursive: true })
  writeFileSync(
    join(pkg, 'package.json'),
    `{"name":"@imunitic/synapse-test","version":"${version}"}`,
  )
  writeFileSync(join(pkg, 'bin', 'synapse-hook'), '')
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    JSON.stringify({
      hooks: {
        SessionStart: [
          {
            hooks: [
              { type: 'command', command: `${join(pkg, 'bin', 'synapse-hook')} session-start` },
            ],
          },
        ],
      },
    }),
  )
  return pkg
}

test('a copy whose version cannot be told is shown, and can be replaced by the npm one', async ({
  page,
}) => {
  // A hook program with no package.json and no synapse beside it.
  const copy = join(world().root, 'unknown-copy')
  mkdirSync(join(copy, 'bin'), { recursive: true })
  writeFileSync(join(copy, 'bin', 'synapse-hook'), '')
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    JSON.stringify({
      hooks: {
        SessionStart: [
          {
            hooks: [
              { type: 'command', command: `${join(copy, 'bin', 'synapse-hook')} session-start` },
            ],
          },
        ],
      },
    }),
  )
  try {
    await openIntegrations(page)
    const card = page.getByLabel('Claude Code', { exact: true })
    await expect(card).toContainText('Installed from another copy or version')
    await card.getByRole('button', { name: 'Update' }).click()
    await expect(card.getByRole('alertdialog')).toContainText(INSTALL)
    await card.getByRole('button', { name: 'Yes, update' }).click()
    await expect(page.getByRole('tab', { name: 'Update Claude Code' })).toBeVisible()
  } finally {
    rmSync(copy, { recursive: true, force: true })
  }
})

test('a newer Synapse than the app has is shown with its version, and nothing is offered', async ({
  page,
}) => {
  const pkg = packageOf('9.0.0')
  try {
    await openIntegrations(page)
    const card = page.getByLabel('Claude Code', { exact: true })
    await expect(card).toContainText("newer than this app's Synapse")
    await expect(card).toContainText('9.0.0')
    await expect(card.getByRole('button')).toHaveCount(0)
  } finally {
    rmSync(pkg, { recursive: true, force: true })
  }
})

test('a Synapse that is the one this app has is up to date, and nothing is offered', async ({
  page,
}) => {
  await openIntegrations(page)
  // The hook program of this app, as the first card says it.
  const hook = (
    await page.getByLabel("This app's Synapse").locator('.mono').last().innerText()
  ).trim()
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    JSON.stringify({
      hooks: { SessionStart: [{ hooks: [{ type: 'command', command: `${hook} session-start` }] }] },
    }),
  )
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await expect(card).toContainText('Installed, up to date')
  await expect(card.getByRole('button')).toHaveCount(0)
})

test('cancelling the question runs nothing', async ({ page }) => {
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await card.getByRole('button', { name: 'Install' }).click()
  await expect(card.getByRole('alertdialog')).toBeVisible()
  await card.getByRole('button', { name: 'Cancel' }).click()
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
  await expect(card).toContainText('Not installed')
  await expect(page.getByRole('tab', { name: /Install Claude Code/ })).toHaveCount(0)
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
})

test('the page says the install is npm in a terminal, and where the hook path stays', async ({
  page,
}) => {
  await openIntegrations(page)
  await expect(page.getByText('Installing and updating run npm in a terminal tab')).toBeVisible()
  await expect(page.getByText('the app writes no hook path of its own')).toBeVisible()
})
