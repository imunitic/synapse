import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { resetWorldSettings, world } from './helpers.ts'

let vault = ''

test.beforeEach(() => {
  resetWorldSettings()
  // The nodes of the graph are notes of the vault.
  vault = join(world().root, 'graph-vault')
  mkdirSync(join(vault, 'synapse', 'widget@main'), { recursive: true })
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Rendering.md'),
    '---\ntitle: Rendering\n---\n# Rendering\n\nHow a scene is drawn.\n',
  )
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Game loop.md'),
    '---\ntitle: Game loop\n---\nThe loop.\n',
  )
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

async function openGraph(page: Page) {
  await page.goto('/')
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Code graph' })).toBeVisible()
}

test('the namespaces that have local files are the choices, with what each has', async ({
  page,
}) => {
  await openGraph(page)
  const choice = page.getByLabel('Namespace', { exact: true })
  await expect(choice.locator('option')).toHaveText(['thin@main', 'widget@main'])
  await choice.selectOption('widget@main')
  await expect(page.getByText(/has a node index, references/)).toBeVisible()
})

test('an exact symbol is searched, with its calls and with every definition and reference', async ({
  page,
}) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Symbol name' }).fill('Render')
  await page.getByRole('button', { name: 'Search' }).click()
  const calls = page.getByRole('region', { name: 'Calls' })
  await expect(calls).toContainText('src/main.adb:30')
  await expect(calls).toContainText('Render (Current);')
  await expect(calls).toContainText('src/loop.adb:8')

  await page.getByRole('checkbox', { name: /Definitions and every reference/ }).check()
  await page.getByRole('button', { name: 'Search' }).click()
  const defs = page.getByRole('region', { name: 'Definitions' })
  await expect(defs).toContainText('src/render.adb:12')
  await expect(defs).toContainText('function')
  await expect(page.getByRole('region', { name: 'References' })).toContainText('src/main.adb:30')
})

test('a name that is not there is said to be, and a name has to be exact', async ({ page }) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Symbol name' }).fill('Rend')
  await page.getByRole('button', { name: 'Search' }).click()
  await expect(page.getByText('The name has to be exact.')).toBeVisible()
})

test('files are found by their words, and the node that covers one opens in the vault', async ({
  page,
}) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('tab', { name: 'Files' }).click()
  await page.getByRole('textbox', { name: 'File path' }).fill('render')
  await page.getByRole('button', { name: /src\/render\.adb/ }).click()
  const owners = page.getByRole('region', { name: 'Owners' })
  await expect(owners).toContainText('is covered by')
  await owners.getByRole('button', { name: 'Rendering' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Rendering' })).toBeVisible()
  await expect(page.getByText('How a scene is drawn.')).toBeVisible()
})

test('the nodes are listed, open in the vault, and the unassigned files are counted', async ({
  page,
}) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('tab', { name: 'Nodes' }).click()
  const nodes = page.getByRole('region', { name: 'Nodes' })
  await expect(nodes).toContainText('Game loop')
  await expect(nodes).toContainText('Rendering')
  await expect(page.getByText('1 file is claimed by no node')).toBeVisible()
  await nodes.getByRole('button', { name: 'Game loop' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Game loop' })).toBeVisible()
})

test('a namespace with no node index says so and leaves the other modes to symbols', async ({
  page,
}) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('thin@main')
  await expect(page.getByRole('tab', { name: 'Files' })).toBeDisabled()
  await expect(page.getByRole('tab', { name: 'Nodes' })).toBeDisabled()
  await expect(page.getByRole('tab', { name: 'Symbol' })).toHaveAttribute('aria-selected', 'true')
  await page.getByRole('textbox', { name: 'Symbol name' }).fill('Only')
  await page.getByRole('checkbox', { name: /Definitions and every reference/ }).check()
  await page.getByRole('button', { name: 'Search' }).click()
  await expect(page.getByRole('region', { name: 'Definitions' })).toContainText('src/only.adb:1')
})

test('the choice of namespace is remembered', async ({ page }) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.reload()
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await expect(page.getByLabel('Namespace', { exact: true })).toHaveValue('widget@main')
})
