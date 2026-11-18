import { expect, test } from './fixtures.ts'
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
    await expect(card.getByRole('button')).toHaveCount(0)
  }
  // One button, for every harness, with the harnesses it covers said beside it.
  const action = page.getByLabel('Install and update')
  await expect(action).toContainText('Claude Code, Codex, OpenCode')
  await expect(action.getByRole('button', { name: 'Install in all harnesses' })).toBeEnabled()
})

const INSTALL =
  'npm install -g @imunitic/synapse@latest @imunitic/synapse-pipeline@latest && synapse-setup configure claude && synapse-pipeline-setup configure claude && synapse-setup configure codex && synapse-pipeline-setup configure codex && synapse-setup configure opencode && synapse-pipeline-setup configure opencode'

// The card with the one button that installs and updates.
const actionOf = (page: import('@playwright/test').Page) => page.getByLabel('Install and update')

// The terminal of the tab that is showing.
const screen = (page: import('@playwright/test').Page) =>
  page.locator('.terminal-view:not([hidden]) .terminal-host')

test('installing asks first, naming the command and what it writes', async ({ page }) => {
  await openIntegrations(page)
  const action = actionOf(page)
  await action.getByRole('button', { name: 'Install in all harnesses' }).click()
  const question = action.getByRole('alertdialog')
  await expect(question).toContainText('Are you sure?')
  await expect(question).toContainText('opens a terminal tab')
  await expect(question).toContainText(INSTALL)
  await expect(question).toContainText('settings.json.bak')
  await expect(question).toContainText('hooks.json.bak')
  await expect(question).toContainText('plugin/synapse.js')
  // Nothing has been opened, or written.
  await expect(page.getByRole('tab', { name: /Install in all harnesses/ })).toHaveCount(0)
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
})

test('saying yes opens a shell tab that runs the npm install, and writes nothing itself', async ({
  page,
}) => {
  await openIntegrations(page)
  const action = actionOf(page)
  await action.getByRole('button', { name: 'Install in all harnesses' }).click()
  await action.getByRole('button', { name: 'Yes, install in all harnesses' }).click()

  await expect(page.getByRole('tab', { name: 'Install in all harnesses' })).toBeVisible()
  // What was typed is on the screen, and it was run: npm's own words are there as well.
  await expect(screen(page)).toContainText('npm install -g @imunitic/synapse@latest')
  await expect(screen(page)).toContainText('synapse-pipeline-setup configure claude')
  await expect(screen(page)).toContainText(/ENOTCACHED|npm error/)
  // The app wrote nothing into any harness; the command in the tab does.
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
  expect(existsSync(join(world().home, '.codex'))).toBe(false)
})

test('the one command configures each harness by its own name', async ({ page }) => {
  await openIntegrations(page)
  const action = actionOf(page)
  await action.getByRole('button', { name: 'Install in all harnesses' }).click()
  const question = action.getByRole('alertdialog')
  for (const name of ['claude', 'codex', 'opencode']) {
    await expect(question).toContainText(`synapse-setup configure ${name}`)
    await expect(question).toContainText(`synapse-pipeline-setup configure ${name}`)
  }
  await action.getByRole('button', { name: 'Yes, install in all harnesses' }).click()
  await expect(screen(page)).toContainText('synapse-setup configure codex')
})

test('a hook program that is gone is shown, and the one button runs the command for every harness', async ({
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
  // Claude's hook is gone and the others have none, so it is more than a repair.
  await actionOf(page).getByRole('button', { name: 'Update in all harnesses' }).click()
  await actionOf(page).getByRole('button', { name: 'Yes, update in all harnesses' }).click()
  await expect(page.getByRole('tab', { name: 'Update in all harnesses' })).toBeVisible()
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
    await actionOf(page).getByRole('button', { name: 'Update in all harnesses' }).click()
    await expect(actionOf(page).getByRole('alertdialog')).toContainText(INSTALL)
    await actionOf(page).getByRole('button', { name: 'Yes, update in all harnesses' }).click()
    await expect(page.getByRole('tab', { name: 'Update in all harnesses' })).toBeVisible()
  } finally {
    rmSync(copy, { recursive: true, force: true })
  }
})

test('a newer Synapse than the app has is shown with its version, and is not replaced by a development build', async ({
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

test('a Synapse that is the one this app has is up to date, and its card offers nothing', async ({
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
  const action = actionOf(page)
  await action.getByRole('button', { name: 'Install in all harnesses' }).click()
  await expect(action.getByRole('alertdialog')).toBeVisible()
  await action.getByRole('button', { name: 'Cancel' }).click()
  await expect(action.getByRole('alertdialog')).toHaveCount(0)
  await expect(page.getByLabel('Claude Code', { exact: true })).toContainText('Not installed')
  await expect(page.getByRole('tab', { name: /Install in all harnesses/ })).toHaveCount(0)
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
})

test("the page says installing is the app's own version, by npm in a terminal, and where the hook path stays", async ({
  page,
}) => {
  await openIntegrations(page)
  await expect(page.getByText('It installs the same version this app bundles')).toBeVisible()
  await expect(page.getByText('is not supported')).toBeVisible()
  await expect(page.getByText('Installing and updating run npm in a terminal tab')).toBeVisible()
  await expect(page.getByText('the app writes no hook path of its own')).toBeVisible()
})
