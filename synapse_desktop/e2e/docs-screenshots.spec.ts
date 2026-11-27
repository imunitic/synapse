// The screenshots of the user documentation in docs/desktop/. Each one is taken through `shot`,
// with its name written out, so that docs/desktop/check-screenshots.sh can read the names from
// this file. With DOCS_SCREENSHOTS_DIR set (`just docs-screenshots`) they are written there; a
// normal run of the end-to-end tests writes them into the test's own output folder, so that a
// screen or a control the docs show that has gone fails the run.

import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { expect, test, type Locator, type Page } from './fixtures.ts'
import { openLaunch, openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

test.use({
  viewport: { width: 1280, height: 800 },
  colorScheme: 'light',
  locale: 'en-US',
  timezoneId: 'UTC',
  // Drawn in software, so that the edges of rounded corners come out the same each time.
  launchOptions: {
    args: ['--disable-gpu', '--force-color-profile=srgb', '--disable-partial-raster'],
  },
})

// The vault the screenshots show: a design under discussion, the task compiled from it, a
// research note with sections, and the nodes of the code graph of widget@main.
const NOTES: Record<string, string> = {
  'Index.md': '# Index\n\nThe notes of the demo project.\n',
  'designs/demo/Checkout redesign.md': [
    '---',
    'title: Checkout redesign',
    'project: demo',
    'note_id: demo-1',
    'tags: [demo, checkout]',
    'updated: 2026-01-14T16:00:00+00:00',
    '---',
    '# Checkout redesign',
    '',
    '## Status',
    'Discussing',
    '',
    '## Problem',
    '',
    'Half of the people who start a checkout leave it on the address step.',
    '',
    '## Options',
    '',
    '- One page with every field, filled from the last order.',
    '- Three short steps, with the address looked up from the postcode.',
    '',
    '## Open questions',
    '',
    '- Do we keep the guest checkout?',
    '',
  ].join('\n'),
  'tasks/demo/Payment retries.md': [
    '---',
    'title: Payment retries',
    'project: demo',
    'task_id: demo-2',
    'status: IN-PROGRESS',
    'updated: 2026-01-15T08:00:00+00:00',
    '---',
    '# Payment retries',
    '',
    'Retry a failed card payment once before the order is cancelled.',
    '',
    '## Checklist',
    '',
    '- [x] Record why a payment failed',
    '- [ ] Retry once after 30 seconds',
    '- [ ] Tell the customer when the retry fails too',
    '',
    '## Notes',
    '',
    'Only card payments are retried.',
    '',
  ].join('\n'),
  'research/Payment provider limits.md': [
    '---',
    'title: Payment provider limits',
    'project: demo',
    'updated: 2026-01-12T09:30:00+00:00',
    '---',
    '# Payment provider limits',
    '',
    'What the payment provider allows, read from its documentation.',
    '',
    '## Rate limits',
    '',
    'At most 100 requests a second for each account.',
    '',
    '### Bursts',
    '',
    'A burst of up to 200 requests is let through once a minute.',
    '',
    '## Retries',
    '',
    'A payment that failed may be retried once with the same key.',
    '',
    '## Sources',
    '',
    '- The provider documentation, "Limits" page.',
    '',
  ].join('\n'),
  'synapse/widget@main/Index.md':
    '---\ntitle: "widget@main"\nnode_type: synapse-index\nproject: widget\nbranch: main\n---\n# widget@main\n',
  'synapse/widget@main/Rendering.md':
    '---\ntitle: Rendering\n---\n# Rendering\n\nHow a scene is drawn.\n',
  'synapse/widget@main/Game loop.md': '---\ntitle: Game loop\n---\nThe loop.\n',
}

let vault = ''

test.beforeEach(async ({ page }) => {
  resetWorldSettings()
  vault = join(world().root, 'docs-vault')
  for (const [path, text] of Object.entries(NOTES)) {
    mkdirSync(join(vault, path, '..'), { recursive: true })
    writeFileSync(join(vault, path), text)
  }
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
  await page.addInitScript(() => localStorage.setItem('synapse-desktop.theme', 'light'))
  await page.clock.setFixedTime(new Date('2026-01-15T10:00:00Z'))
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

// The checkout the app's programs were built in, which the Integrations page names.
const CHECKOUT = resolve(import.meta.dirname, '..', '..')

// What shows a time, a folder of the world, which is made anew for each run of the tests, or a
// folder of this machine: covered, so that a screenshot is the same from one run to the next.
function changing(page: Page): Locator[] {
  const root = world().root
  const summary = page.getByLabel('Summary').locator('dd')
  return [
    summary.nth(0),
    summary.nth(1),
    page.locator('.muted.small', { hasText: /ago$|^just now$/ }),
    page.locator('.statusbar .mono'),
    page.getByText(root),
    page.locator(`input[value*="${root}"]`),
    page.getByText(CHECKOUT),
  ]
}

async function shot(page: Page, name: string, mask: Locator[] = []): Promise<void> {
  const dir = process.env.DOCS_SCREENSHOTS_DIR ?? test.info().outputPath()
  mkdirSync(dir, { recursive: true })
  await page.screenshot({
    path: join(dir, `${name}.png`),
    mask: [...changing(page), ...mask],
    maskColor: '#d4d4d8',
    animations: 'disabled',
    caret: 'hide',
  })
}

async function openSettings(page: Page, category: string) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page
    .locator('.settings-item')
    .filter({ hasText: new RegExp(`^${category}`) })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: category })).toBeVisible()
}

async function openNote(page: Page, folder: string, title: string) {
  await page.goto('/')
  await openSection(page, 'Vault')
  const tree = sidePanel(page).getByLabel('Notes', { exact: true })
  await tree.getByRole('button', { name: new RegExp(folder) }).click()
  if (folder !== 'research') await tree.getByRole('button', { name: 'demo', exact: true }).click()
  await tree.getByRole('button', { name: title }).click()
  await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible()
}

async function openFixtureRun(page: Page) {
  await page.goto('/')
  await openSection(page, 'Executions')
  await sidePanel(page).locator('.list-row[data-execution="exec-fixture1"] .list-item').click()
  await expect(page.getByRole('heading', { level: 1, name: 'exec-fixture1' })).toBeVisible()
}

test('getting started: choosing the vault', async ({ page }) => {
  await openSettings(page, 'Vault')
  await expect(page.getByLabel('Vault folder')).toContainText('docs-vault')
  await expect(page.getByText(/A change is written to/)).toBeVisible()
  await shot(page, 'getting-started-vault')
})

test('getting started: installing Synapse into the harnesses', async ({ page }) => {
  await openSettings(page, 'Integrations')
  await expect(page.getByLabel("This app's Synapse")).toContainText('Version')
  await shot(page, 'getting-started-integrations')
})

test('the home page', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(page.getByLabel('Setup check')).toBeVisible()
  await shot(page, 'home')
})

test('the code graph', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Code graph' })).toBeVisible()
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Symbol name' }).fill('Render')
  await page.getByRole('button', { name: 'Search' }).click()
  await expect(page.getByRole('region', { name: 'Calls' })).toContainText('src/main.adb:30')
  await shot(page, 'code-graph')
})

test('the terminals', async ({ page }) => {
  await page.goto('/')
  await openLaunch(page)
  await shot(page, 'terminals')
})

test('the definitions', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await expect(
    sidePanel(page).getByRole('button', { name: 'Develop_Feature', exact: true }),
  ).toBeVisible()
  await shot(page, 'definitions')
})

test('the page of a pipeline', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Develop_Feature', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Develop_Feature' })).toBeVisible()
  await expect(page.getByText('Edges and limits')).toBeVisible()
  await shot(page, 'definition-details')
})

test('the run dialog', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page)
    .locator('.list-entry', { hasText: 'Develop_Feature' })
    .getByRole('button', { name: 'Run Develop_Feature' })
    .click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeEnabled()
  await shot(page, 'run-dialog')
})

test('the executions', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Executions')
  await expect(
    sidePanel(page).locator('.list-row[data-execution="exec-fixture1"] .list-item'),
  ).toBeVisible()
  await shot(page, 'executions')
})

test('the page of a run', async ({ page }) => {
  await openFixtureRun(page)
  await expect(page.getByLabel('Trace')).toBeVisible()
  await shot(page, 'execution-page')
})

test('the vault', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Vault', exact: true }).first().click()
  await expect(page.getByRole('heading', { level: 1, name: 'What needs a decision' })).toBeVisible()
  await expect(page.locator('.content')).toContainText('Checkout redesign')
  await shot(page, 'vault')
})

test('a note', async ({ page }) => {
  await openNote(page, 'designs', 'Checkout redesign')
  await shot(page, 'note')
})

test('the outline of a note', async ({ page }) => {
  await openNote(page, 'research', 'Payment provider limits')
  await page.getByRole('button', { name: /^Show or hide the outline/ }).click()
  const outline = page.getByRole('complementary', { name: 'Outline' })
  await expect(outline.getByRole('navigation', { name: 'Headings' })).toBeVisible()
  await shot(page, 'note-outline')
})

test('what a run changed, in the Changes sidebar', async ({ page }) => {
  await openFixtureRun(page)
  await page.getByRole('button', { name: /^Show or hide the changes/ }).click()
  const sidebar = page.getByRole('complementary', { name: 'Changes' })
  await expect(sidebar).toContainText('3 files changed')
  await expect(sidebar.getByRole('region', { name: 'Changes in src/render.adb' })).toBeVisible()
  await shot(page, 'changes-sidebar')
})

test('the settings', async ({ page }) => {
  await openSettings(page, 'General')
  await shot(page, 'settings')
})
