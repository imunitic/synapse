import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { resetWorldSettings, world } from './helpers.ts'

test.beforeEach(() => {
  resetWorldSettings()
})

test.afterEach(() => {
  resetWorldSettings()
})

const card = (page: Page) => page.getByLabel('Needs attention')

test('the app opens on the home page, and the rail leads back to it', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Home' })).toHaveAttribute('aria-selected', 'true')

  await page.getByRole('button', { name: 'Settings', exact: true }).click()
  await page.locator('.settings-item').filter({ hasText: 'General' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()

  await page.getByRole('button', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Home' })).toHaveAttribute('aria-selected', 'true')
})

test('what is not set up is listed, each step leading to the page that does it', async ({
  page,
}) => {
  await page.goto('/')
  const steps = page.getByLabel('Get set up')
  await expect(steps).toContainText('Choose a vault')
  await expect(steps).toContainText('Install Synapse in a harness')
  // A work directory has a default, so it is not a step.
  await expect(steps.getByRole('button', { name: /Choose a vault/ })).toBeEnabled()
  await steps.getByRole('button', { name: /Choose a vault/ }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Vault' })).toBeVisible()
  // A missing vault is not a fault, so Needs attention does not list it.
  await page.getByRole('button', { name: 'Home', exact: true }).click()
  await expect(card(page)).not.toContainText('No vault is configured')
})

test('a run that failed lately is listed with why, and opens', async ({ page }) => {
  const id = 'exec-home-1'
  const dir = join(world().work, 'pipelines', id)
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'execution.json'),
    JSON.stringify({
      format: 'synapse-pipeline-execution/v1',
      id,
      pipeline: 'Ship_Release',
      started: new Date().toISOString(),
      ended: new Date().toISOString(),
      status: 'failed',
      current_step: null,
      state: { steps_run: 1, failure: { step: 'Build', message: 'the build exited with 1' } },
    }),
  )
  try {
    await page.goto('/')
    const item = card(page).getByRole('button', { name: /Ship_Release failed/ })
    await expect(item).toContainText('Build: the build exited with 1')
    await item.click()
    await expect(page.getByRole('tab', { name: id })).toBeVisible()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the vault says what needs a decision', async ({ page }) => {
  const vault = join(world().root, 'attention-vault')
  mkdirSync(join(vault, 'designs', 'p'), { recursive: true })
  mkdirSync(join(vault, 'tasks', 'p'), { recursive: true })
  writeFileSync(
    join(vault, 'designs', 'p', 'Talk.md'),
    '---\ntitle: Talk\nnote_id: p-1\n---\n## Status\nDiscussing\n',
  )
  writeFileSync(
    join(vault, 'tasks', 'p', 'Work.md'),
    '---\ntitle: Work\ntask_id: p-2\nstatus: IN-PROGRESS\n---\n- [ ] one\n- [ ] two\n',
  )
  const before = readFileSync(world().conf, 'utf8')
  writeFileSync(world().conf, `${before}SYNAPSE_VAULT_DIR=${vault}\n`)
  try {
    await page.goto('/')
    await expect(card(page)).toContainText('Discussing')
    await expect(card(page)).toContainText('p-1')
    await expect(card(page)).toContainText('In progress (unchecked items)')
    await expect(card(page)).toContainText('p-2')
    await expect(card(page)).toContainText('2 unchecked')
    await expect(card(page)).not.toContainText('No vault is configured')

    const summary = page.getByRole('region', { name: 'Vault', exact: true })
    await expect(summary).toContainText(vault)
    await expect(summary.locator('.count').filter({ hasText: 'Discussing' })).toContainText('1')
    await expect(summary.locator('.count').filter({ hasText: 'In progress' })).toContainText('1')
    // The step is done now, and a done step is ticked and cannot be pressed.
    await expect(
      page.getByLabel('Get set up').getByRole('button', { name: /Choose a vault/ }),
    ).toBeDisabled()
  } finally {
    rmSync(vault, { recursive: true, force: true })
  }
})

test('the pipelines card counts the week and lists the latest runs', async ({ page }) => {
  const dir = join(world().work, 'pipelines', 'exec-home-2')
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'execution.json'),
    JSON.stringify({
      format: 'synapse-pipeline-execution/v1',
      id: 'exec-home-2',
      pipeline: 'Develop_Feature',
      started: new Date().toISOString(),
      ended: new Date().toISOString(),
      status: 'completed',
      current_step: null,
      state: { steps_run: 2 },
    }),
  )
  try {
    await page.goto('/')
    const pipelines = page.getByLabel('Pipelines', { exact: true })
    await expect(pipelines.locator('.tile').filter({ hasText: 'completed' })).toContainText(/[1-9]/)
    await expect(pipelines.getByRole('button', { name: /Develop_Feature/ })).toContainText(
      'completed',
    )
    await expect(pipelines).toContainText('pipelines defined')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a quick action starts a terminal, which then shows as running', async ({ page }) => {
  await page.goto('/')
  // A harness needs a folder to work in, which the terminals page asks for, so the
  // quick actions are a shell and a pipeline.
  await expect(page.getByRole('group', { name: 'Quick actions' }).getByRole('button')).toHaveText([
    'New shell',
    'New pipeline',
  ])
  await page
    .getByRole('group', { name: 'Quick actions' })
    .getByRole('button', { name: 'New shell' })
    .click()
  await expect(page.getByRole('tab', { name: 'Terminals' })).toBeVisible()
  await page.getByRole('button', { name: 'Home', exact: true }).click()
  const running = page.getByLabel('Running now')
  await expect(running).toContainText('Shell 1')
  await running.getByRole('button', { name: /Shell 1/ }).click()
  await expect(page.locator('.terminal-host')).toBeVisible()
})

test('the code graph card lists the graphs, and a choice opens its search', async ({ page }) => {
  await page.goto('/')
  const graph = page.getByRole('region', { name: 'Code graph', exact: true })
  await expect(graph).toContainText('Search the symbols, files and nodes of 2 graphs')
  await graph.getByRole('button', { name: 'widget@main' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Code graph' })).toBeVisible()
  await expect(page.getByLabel('Namespace', { exact: true })).toHaveValue('widget@main')
})
