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

test('installing writes the hooks, skills and commands, and the page then says it is up to date', async ({
  page,
}) => {
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await card.getByRole('button', { name: 'Install' }).click()
  await expect(card.getByRole('alertdialog')).toContainText('Are you sure?')
  await expect(card.getByRole('alertdialog')).toContainText('settings.json.bak')
  await card.getByRole('button', { name: 'Yes, install' }).click()
  await expect(card).toContainText('Installed, up to date')
  await expect(card.getByRole('status')).toContainText('configured')
  await expect(card.getByRole('button', { name: 'Reinstall' })).toBeVisible()

  const settings = readFileSync(join(world().home, '.claude', 'settings.json'), 'utf8')
  expect(settings).toContain('synapse-hook session-start')
  expect(existsSync(join(world().home, '.claude', 'skills', 'synapse-pipeline', 'SKILL.md'))).toBe(
    true,
  )
  expect(existsSync(join(world().home, '.claude', 'skills', 'synapse-query', 'SKILL.md'))).toBe(
    true,
  )
  // The other harnesses were not touched.
  expect(existsSync(join(world().home, '.codex'))).toBe(false)
  await expect(page.getByLabel('Codex', { exact: true })).toContainText('Not installed')
})

test('OpenCode and Codex are installed the way each takes it', async ({ page }) => {
  await openIntegrations(page)
  await page
    .getByLabel('OpenCode', { exact: true })
    .getByRole('button', { name: 'Install' })
    .click()
  await page
    .getByLabel('OpenCode', { exact: true })
    .getByRole('button', { name: 'Yes, install' })
    .click()
  await expect(page.getByLabel('OpenCode', { exact: true })).toContainText('Installed, up to date')
  expect(
    readFileSync(join(world().home, '.config', 'opencode', 'plugin', 'synapse.js'), 'utf8'),
  ).toContain('synapse-hook')

  await page.getByLabel('Codex', { exact: true }).getByRole('button', { name: 'Install' }).click()
  await page
    .getByLabel('Codex', { exact: true })
    .getByRole('button', { name: 'Yes, install' })
    .click()
  await expect(page.getByLabel('Codex', { exact: true })).toContainText('Installed, up to date')
  expect(existsSync(join(world().home, '.codex', 'hooks.json'))).toBe(true)
})

test('a hook program that is gone is shown, and installing again repairs it', async ({ page }) => {
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    JSON.stringify({
      theme: 'dark',
      hooks: {
        SessionStart: [
          { hooks: [{ type: 'command', command: '/gone/bin/synapse-hook session-start' }] },
        ],
      },
    }),
  )
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await expect(card).toContainText('Its hook program is missing')
  await card.getByRole('button', { name: 'Repair' }).click()
  await card.getByRole('button', { name: 'Yes, repair' }).click()
  await expect(card).toContainText('Installed, up to date')
  const settings = readFileSync(join(world().home, '.claude', 'settings.json'), 'utf8')
  expect(settings).not.toContain('/gone/bin')
  expect(settings).toContain('"theme": "dark"')
})

test('a newer Synapse than the app has is shown with its version, and is not written over', async ({
  page,
}) => {
  const pkg = join(world().root, 'newer-package')
  mkdirSync(join(pkg, 'bin'), { recursive: true })
  writeFileSync(join(pkg, 'package.json'), '{"name":"@imunitic/synapse-test","version":"9.0.0"}')
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
  try {
    await openIntegrations(page)
    const card = page.getByLabel('Claude Code', { exact: true })
    await expect(card).toContainText("newer than this app's Synapse")
    await expect(card).toContainText('9.0.0')
    await expect(card.getByRole('button', { name: 'Update' })).toBeDisabled()
  } finally {
    rmSync(pkg, { recursive: true, force: true })
  }
})

test('cancelling the question installs nothing', async ({ page }) => {
  await openIntegrations(page)
  const card = page.getByLabel('Claude Code', { exact: true })
  await card.getByRole('button', { name: 'Install' }).click()
  await expect(card.getByRole('alertdialog')).toBeVisible()
  await card.getByRole('button', { name: 'Cancel' }).click()
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
  await expect(card).toContainText('Not installed')
  expect(existsSync(join(world().home, '.claude', 'settings.json'))).toBe(false)
})
