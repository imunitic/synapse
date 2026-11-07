import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { openSection, world } from './helpers.ts'

const injected = () => join(world().data, 'synapse-desktop', 'injected')

// The terminal of the tab that is showing.
const screen = (page: Page) => page.locator('.terminal-view:not([hidden]) .terminal-host')

async function openTerminals(page: Page, folder = '') {
  await page.goto('/')
  await openSection(page, 'Terminals')
  await page.getByLabel('Start in').fill(folder)
}

async function type(page: Page, text: string) {
  await screen(page).click()
  await page.keyboard.type(text)
  await page.keyboard.press('Enter')
}

test('a new shell starts in the home folder and runs what is typed', async ({ page }) => {
  await openTerminals(page)
  await page.getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()

  // The sum is done by the shell: its result is not in the line that was typed.
  await type(page, 'echo sum-$((40+2)) home=$HOME')
  await expect(screen(page)).toContainText(`sum-42 home=${world().home}`)
  await type(page, 'pwd')
  await expect(screen(page)).toContainText(world().home)
})

test('claude typed in the shell starts with Synapse loaded for that run only', async ({ page }) => {
  await openTerminals(page, world().root)
  await page.getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByText('started here load Synapse for that run only')).toBeVisible()

  // The wrapper is the claude of this shell; nothing runs until it is.
  const wrapper = join(injected(), 'shims', 'claude')
  await type(page, 'echo which=$(command -v claude)')
  await expect(screen(page)).toContainText(`which=${wrapper}`)

  await type(page, 'claude one two')
  await expect(screen(page)).toContainText('STUB claude args: --add-dir')
  await expect(screen(page)).toContainText('one two')
  await expect(screen(page)).toContainText(join(injected(), 'claude', 'overlay'))
  // Nothing was installed in the home.
  expect(existsSync(join(world().home, '.claude'))).toBe(false)
  expect(
    existsSync(
      join(injected(), 'claude', 'overlay', '.claude', 'skills', 'synapse-query', 'SKILL.md'),
    ),
  ).toBe(true)
})

test('codex and opencode typed in the shell get their homes of their own', async ({ page }) => {
  await openTerminals(page, world().root)
  await page.getByRole('button', { name: 'New shell' }).click()
  await type(page, 'codex')
  await expect(screen(page)).toContainText(`CODEX_HOME=${join(injected(), 'codex')}`)
  await type(page, 'quit')
  await type(page, 'opencode')
  await expect(screen(page)).toContainText(`OPENCODE_CONFIG_DIR=${join(injected(), 'opencode')}`)
})

test('a harness that has Synapse installed is not wrapped', async ({ page }) => {
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    '{"hooks":{"SessionStart":[{"hooks":[{"command":"/x/synapse-hook start"}]}]}}',
  )
  try {
    await openTerminals(page, world().root)
    await page.getByRole('button', { name: 'New shell' }).click()
    await expect(page.getByText('codex, opencode started here')).toBeVisible()
    await type(page, 'echo which=$(command -v claude)')
    await expect(screen(page)).toContainText(`which=${world().bin}/claude`)
  } finally {
    rmSync(join(world().home, '.claude'), { recursive: true, force: true })
  }
})

test('a harness can be started directly in a tab of its own', async ({ page }) => {
  await openTerminals(page, world().root)
  await page.getByRole('button', { name: 'Claude Code' }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toBeVisible()
  await expect(page.getByText('Synapse is loaded for this session only')).toBeVisible()
  await expect(screen(page)).toContainText('STUB claude args: --add-dir')
  await expect(screen(page)).toContainText(`cwd: ${world().root}`)

  await type(page, 'hello')
  await expect(screen(page)).toContainText('typed: hello')
  await type(page, 'quit')
  await expect(screen(page)).toContainText('the program ended with code 7')
  await expect(page.getByText('The session ended.')).toBeVisible()
  await page.getByRole('button', { name: 'Close the tab' }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toHaveCount(0)
})

test('shells have tabs: each goes on while the others show, and closing one leaves the rest', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await page.getByRole('button', { name: 'New shell' }).click()
  await type(page, 'MARK=first; echo tab-$MARK')
  await expect(screen(page)).toContainText('tab-first')

  await page.getByRole('button', { name: 'New shell', exact: true }).first().click()
  await expect(page.getByRole('tab', { name: 'Shell 2' })).toBeVisible()
  // A shell of its own: the variable of the first one is not in it.
  await type(page, 'echo second-${MARK:-none}')
  await expect(screen(page)).toContainText('second-none')

  await page.getByRole('tab', { name: 'Shell 1' }).click()
  await type(page, 'echo again-$MARK')
  await expect(screen(page)).toContainText('again-first')

  await page.getByRole('button', { name: 'Close Shell 1' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toHaveCount(0)
  await expect(page.getByRole('tab', { name: 'Shell 2' })).toHaveAttribute('aria-selected', 'true')
})

test('sessions go on while another page of the app shows', async ({ page }) => {
  await openTerminals(page, world().root)
  await page.getByRole('button', { name: 'New shell' }).click()
  await type(page, 'MARK=kept')

  await openSection(page, 'Settings')
  await page.getByRole('button', { name: 'All settings' }).click()
  await expect(page.getByRole('heading', { name: 'Synapse settings' })).toBeVisible()
  await expect(page.locator('.terminal-host')).toBeHidden()

  await page.getByRole('tab', { name: 'Terminals' }).click()
  await type(page, 'echo back-$MARK')
  await expect(screen(page)).toContainText('back-kept')
})

test('a folder that is not one is said in the tab', async ({ page }) => {
  await openTerminals(page, join(world().root, 'nowhere'))
  await page.getByRole('button', { name: 'New shell' }).click()
  await expect(screen(page)).toContainText('is not a folder')
  await expect(page.getByText('The session ended.')).toBeVisible()
})
