import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  launchCard,
  openLaunch,
  openSection,
  resetWorldSettings,
  sidePanel,
  world,
} from './helpers.ts'

test.beforeEach(() => {
  resetWorldSettings()
})

test.afterEach(() => {
  resetWorldSettings()
})

type Status = 'ok' | 'warn' | 'fail'
interface Finding {
  key: string
  name: string
  status: Status
  detail: string
  value: string
}

const finding = (key: string, status: Status, detail: string, value = ''): Finding => ({
  key,
  name: key,
  status,
  detail,
  value,
})

// What `synapse doctor --install` says, for a state a real machine cannot be put in reliably.
const diagnosis = (...findings: Finding[]) => ({
  findings,
  counts: {
    ok: findings.filter((f) => f.status === 'ok').length,
    warn: findings.filter((f) => f.status === 'warn').length,
    fail: findings.filter((f) => f.status === 'fail').length,
  },
})

const BASE = [
  finding('git', 'ok', 'git version 2', ''),
  finding('config', 'ok', '/c/synapse.conf', '/c/synapse.conf'),
  finding('vault', 'ok', '/v', '/v'),
]

const NO_HARNESS = diagnosis(
  ...BASE,
  finding('claude', 'warn', 'not installed'),
  finding('codex', 'warn', 'not installed'),
  finding('opencode', 'warn', 'not installed'),
  finding(
    'harness',
    'fail',
    'none of claude, codex or opencode is installed -- nothing will work without it',
  ),
)

const CODEX_MISSING = diagnosis(
  ...BASE,
  finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
  finding('codex', 'ok', 'not installed'),
  finding('opencode', 'ok', '2.2, Synapse installed', '/bin/opencode'),
)

const ALL_FINE = diagnosis(
  ...BASE,
  finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
  finding('codex', 'ok', '0.1, Synapse installed', '/bin/codex'),
  finding('opencode', 'ok', '2.2, Synapse installed', '/bin/opencode'),
)

// Answers every ask of the check with a document, which a test can change. It is asked more
// than once on a page that opens, since development builds run an effect twice.
async function answering(page: Page, first: ReturnType<typeof diagnosis>) {
  let current = first
  await page.route('**/api/call/getDiagnosis', (route) =>
    route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, result: current }),
    }),
  )
  return (next: ReturnType<typeof diagnosis>) => {
    current = next
  }
}

const card = (page: Page) => page.getByLabel('Setup check')

async function grantClipboard(context: BrowserContext) {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
}

test('with no harness the card says so and gives a command for each, which can be copied', async ({
  page,
  context,
}) => {
  await grantClipboard(context)
  await answering(page, NO_HARNESS)
  await page.goto('/')
  await expect(card(page)).toContainText('Needs doing')
  await expect(card(page)).toContainText('nothing will work without it')
  // One of several missing is nobody's fault, but all of them are said in one finding.
  await expect(card(page).locator('.setup-finding')).toHaveCount(1)
  for (const command of [
    'npm install -g @anthropic-ai/claude-code',
    'npm install -g @openai/codex',
    'npm install -g opencode-ai',
  ]) {
    await expect(card(page)).toContainText(command)
  }
  await card(page).getByRole('button', { name: 'Copy the command for Codex' }).click()
  await expect(
    card(page).getByRole('button', { name: 'Copied the command for Codex' }),
  ).toBeVisible()
  expect(await page.evaluate('navigator.clipboard.readText()')).toBe('npm install -g @openai/codex')
  // The error cannot be put aside.
  await expect(card(page).getByRole('button', { name: 'Dismiss' })).toHaveCount(0)
})

test('with no harness none can be started or chosen, and a shell still can', async ({ page }) => {
  await answering(page, NO_HARNESS)
  await page.goto('/')
  await expect(card(page)).toBeVisible()

  await openLaunch(page)
  for (const name of ['Claude Code', 'Codex', 'OpenCode'] as const) {
    const card = launchCard(page, name)
    await expect(card).toContainText(`Not found. ${name} was not found on PATH`)
    // Nothing in it can be started.
    await expect(card.getByRole('button')).toHaveCount(0)
  }
  await expect(launchCard(page, 'Shell').getByRole('button', { name: 'New shell' })).toBeEnabled()

  await openSection(page, 'Settings')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: /^General/ }).click()
  const choice = page.getByLabel('Default harness', { exact: true })
  for (const value of ['Claude', 'Codex', 'Opencode']) {
    await expect(choice.locator(`option[value="${value}"]`)).toBeDisabled()
  }
  await panel.getByRole('button', { name: /^Integrations/ }).click()
  const integration = page.getByLabel('Codex', { exact: true })
  await expect(integration).toContainText('was not found on PATH')
  await expect(integration.getByRole('button').first()).toBeDisabled()
})

test('one harness that is missing is held back and is not a finding', async ({ page }) => {
  await answering(page, CODEX_MISSING)
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(card(page)).toHaveCount(0)

  await openLaunch(page)
  await expect(launchCard(page, 'Codex')).toContainText('Not found.')
  await expect(launchCard(page, 'Codex').getByRole('button')).toHaveCount(0)
  await expect(launchCard(page, 'Claude Code')).not.toContainText('Not found.')
  await expect(launchCard(page, 'Claude Code').getByLabel('Another folder')).toBeVisible()
  await expect(launchCard(page, 'OpenCode')).not.toContainText('Not found.')
})

test('a harness without Synapse points to the page that installs it', async ({ page }) => {
  await answering(
    page,
    diagnosis(
      ...BASE,
      finding(
        'claude',
        'warn',
        '2.1, Synapse is not installed in it -- run `synapse configure claude`',
        '/bin/claude',
      ),
      finding('codex', 'ok', 'not installed'),
      finding('opencode', 'ok', 'not installed'),
    ),
  )
  await page.goto('/')
  await expect(card(page)).toContainText('Claude Code')
  await expect(card(page)).toContainText('Worth a look')
  await card(page).getByRole('button', { name: 'Install Synapse in a harness' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Integrations' })).toBeVisible()
})

test('a missing vault points to the vault settings', async ({ page }) => {
  await answering(
    page,
    diagnosis(
      finding('git', 'ok', 'git version 2'),
      finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
      finding('config', 'fail', 'no synapse.conf found'),
      finding('vault', 'fail', 'SYNAPSE_VAULT_DIR is not set anywhere'),
    ),
  )
  await page.goto('/')
  // Without a configuration file and without a vault is one thing to do.
  await expect(card(page).locator('.setup-finding')).toHaveCount(1)
  await card(page).getByRole('button', { name: 'Choose a vault' }).first().click()
  await expect(page.getByRole('heading', { level: 1, name: 'Vault' })).toBeVisible()
})

test('a warning is put aside, comes back when asked, and stays put aside after a reload', async ({
  page,
}) => {
  await answering(
    page,
    diagnosis(
      ...BASE,
      finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
      finding('pipeline', 'warn', 'synapse-pipeline is not on PATH'),
    ),
  )
  await page.goto('/')
  await expect(card(page)).toContainText('synapse-pipeline is not on PATH')
  await card(page).getByRole('button', { name: 'Dismiss' }).click()
  await expect(card(page)).toContainText('Nothing needs doing.')
  await expect(card(page)).toContainText('1 warning put aside')

  await page.reload()
  await expect(card(page)).toContainText('Nothing needs doing.')
  await card(page)
    .getByRole('button', { name: /1 warning put aside/ })
    .click()
  await expect(card(page)).toContainText('synapse-pipeline is not on PATH')
  await expect(card(page)).not.toContainText('Nothing needs doing.')
})

test('check again asks again, and the card goes when nothing is left', async ({ page }) => {
  const answer = await answering(page, NO_HARNESS)
  await page.goto('/')
  await expect(card(page)).toContainText('Needs doing')
  answer(ALL_FINE)
  await card(page).getByRole('button', { name: 'Check again' }).click()
  await expect(card(page)).toHaveCount(0)
})

test('every check can be looked at, the ones that are fine too', async ({ page }) => {
  await answering(
    page,
    diagnosis(
      ...BASE,
      finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
      finding('pipeline', 'warn', 'not on PATH'),
    ),
  )
  await page.goto('/')
  await card(page)
    .getByRole('button', { name: /^All 5 checks/ })
    .click()
  const all = card(page).getByRole('list', { name: 'All checks' })
  await expect(all.getByRole('listitem')).toHaveCount(5)
  await expect(all).toContainText('git')
  await expect(all).toContainText('2.1, Synapse installed')
})

test('a check that could not be made says so, and can be tried again', async ({ page }) => {
  let failing = true
  await page.route('**/api/call/getDiagnosis', (route) => {
    const body = failing
      ? { ok: false, error: 'synapse doctor printed nothing' }
      : { ok: true, result: NO_HARNESS }
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })
  })
  await page.goto('/')
  await expect(card(page)).toContainText(
    'Could not check the setup: synapse doctor printed nothing',
  )
  failing = false
  await card(page).getByRole('button', { name: 'Check again' }).click()
  await expect(card(page)).toContainText('nothing will work without it')
})

test('until it is known nothing is held back', async ({ page }) => {
  await page.route('**/api/call/getDiagnosis', () => new Promise(() => undefined))
  await page.goto('/')
  await openLaunch(page)
  await expect(launchCard(page, 'Codex')).not.toContainText('Not found.')
  await expect(launchCard(page, 'Codex').getByLabel('Another folder')).toBeVisible()
})

async function openVaultSettings(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^Vault/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'Vault' })).toBeVisible()
}

test('a vault is made from a folder that is not there, with an Index.md', async ({ page }) => {
  const root = mkdtempSync(join(tmpdir(), 'synapse-desktop-newvault-'))
  const vault = join(root, 'my', 'vault')
  try {
    await openVaultSettings(page)
    const section = page.getByLabel('Vault folder', { exact: true })
    await section.getByPlaceholder('/path/to/a/vault').fill(vault)
    // A folder that is not there cannot be used as it is, and can be made.
    await expect(section.getByRole('button', { name: 'Use this vault' })).toBeDisabled()
    await section.getByRole('button', { name: 'Create this vault' }).click()
    await expect(section.getByText(vault, { exact: true }).first()).toBeVisible()
    expect(existsSync(join(vault, 'Index.md'))).toBe(true)
    expect(readFileSync(join(vault, 'Index.md'), 'utf8')).toContain('# Index')
    expect(readFileSync(world().conf, 'utf8')).toContain(`SYNAPSE_VAULT_DIR=${vault}`)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('a folder with notes gets an Index.md and keeps its notes', async ({ page }) => {
  const root = mkdtempSync(join(tmpdir(), 'synapse-desktop-oldvault-'))
  mkdirSync(join(root, 'notes'), { recursive: true })
  writeFileSync(join(root, 'notes', 'one.md'), '# one\n')
  try {
    await openVaultSettings(page)
    const section = page.getByLabel('Vault folder', { exact: true })
    await section.getByPlaceholder('/path/to/a/vault').fill(root)
    await section.getByRole('button', { name: 'Add an Index.md and use it' }).click()
    await expect(section.getByText(root, { exact: true }).first()).toBeVisible()
    expect(existsSync(join(root, 'Index.md'))).toBe(true)
    expect(readFileSync(join(root, 'notes', 'one.md'), 'utf8')).toBe('# one\n')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
