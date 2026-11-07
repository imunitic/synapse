import { expect, test, type Page } from '@playwright/test'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { resetWorldSettings, world } from './helpers.ts'

let vault = ''

// A repository folder on branch main, named `name`, so its namespace is `name@main`.
function repository(name: string, parent = join(world().root, 'repos')): string {
  const path = join(parent, name)
  rmSync(path, { recursive: true, force: true })
  mkdirSync(join(path, 'src'), { recursive: true })
  writeFileSync(join(path, 'src', 'render.adb'), 'x')
  const git = (...args: string[]) => spawnSync('git', args, { cwd: path, encoding: 'utf8' })
  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test')
  git('add', '-A')
  git('commit', '-q', '-m', 'files')
  return path
}

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
    join(vault, 'synapse', 'widget@main', 'Index.md'),
    '---\ntitle: "widget@main"\nnode_type: synapse-index\nproject: widget\nbranch: main\n---\n# widget@main\n',
  )
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Game loop.md'),
    '---\ntitle: Game loop\n---\nThe loop.\n',
  )
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(join(world().root, 'repos'), { recursive: true, force: true })
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

test('health needs the repository, which is checked when it is saved', async ({ page }) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('tab', { name: 'Health' }).click()
  await expect(page.getByText('Save the folder of the repository above')).toBeVisible()

  // A folder that is not a repository is refused, with the reason.
  const folder = page.getByRole('textbox', { name: 'Repository folder' })
  await folder.fill(join(world().root, 'not-a-repository'))
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByRole('alert').filter({ hasText: 'not a folder' })).toBeVisible()

  await folder.fill(repository('widget'))
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('on widget@main')
})

test('health lists the stale nodes, the drift and what is not grounded, and a node opens', async ({
  page,
}) => {
  const repo = repository('widget')
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill(repo)
  await page.getByRole('button', { name: 'Save' }).click()
  await page.getByRole('tab', { name: 'Health' }).click()

  await expect(page.getByText('2 nodes need attention.')).toBeVisible()
  const stale = page.getByRole('region', { name: 'Stale nodes' })
  await expect(stale).toContainText('Rendering')
  await expect(stale).toContainText('Game loop')
  await expect(stale).toContainText('no sources_digest')
  await expect(page.getByRole('region', { name: 'Drift' })).toContainText('no commit recorded')
  await expect(page.getByRole('region', { name: 'Not grounded' })).toContainText('None.')

  await stale.getByRole('button', { name: /Rendering/ }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Rendering' })).toBeVisible()
})

test('a checkout of another branch is warned about, and the repository can be removed', async ({
  page,
}) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill(repository('other'))
  await page.getByRole('button', { name: 'Save' }).click()
  const row = page.getByLabel('Repository', { exact: true })
  await expect(row).toContainText('is on other@main, not widget@main')

  await row.getByRole('button', { name: 'Remove' }).click()
  await expect(page.getByRole('textbox', { name: 'Repository folder' })).toBeVisible()
})

test('a namespace with no node index has no health to read', async ({ page }) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('thin@main')
  await expect(page.getByRole('tab', { name: 'Health' })).toBeDisabled()
})

test('a stale graph with a repository saved is on the home page, and leads to its page', async ({
  page,
}) => {
  const repo = repository('widget')
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill(repo)
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('on widget@main')

  await page.getByRole('button', { name: 'Home', exact: true }).click()
  const attention = page.getByLabel('Needs attention')
  await expect(attention).toContainText('Code graphs')
  await attention.getByRole('button', { name: /widget@main: 2 nodes are stale/ }).click()
  await expect(page.getByLabel('Namespace', { exact: true })).toHaveValue('widget@main')
})

async function saveRepository(page: Page, path: string) {
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill(path)
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('widget@main')
}

test('changing a graph needs the repository, and says so without one', async ({ page }) => {
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('tab', { name: 'Manage' }).click()
  await expect(page.getByText('Save the folder of the repository above to change')).toBeVisible()
})

test('deleting a graph shows what goes and asks first, and cancelling deletes nothing', async ({
  page,
}) => {
  await openGraph(page)
  await saveRepository(page, repository('widget'))
  await page.getByRole('tab', { name: 'Manage' }).click()
  const card = page.getByRole('region', { name: 'Delete this graph' })
  await card.getByRole('button', { name: 'Delete the graph…' }).click()
  const question = card.getByRole('alertdialog')
  await expect(question).toContainText('Are you sure?')
  await expect(question).toContainText('This deletes the graph of widget@main.')
  await expect(question).toContainText('Its 2 nodes will be removed from the vault.')
  await expect(question).toContainText('synapse/widget@main')

  await question.getByRole('button', { name: 'Cancel' }).click()
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
  expect(existsSync(join(vault, 'synapse', 'widget@main', 'Rendering.md'))).toBe(true)
})

test('confirming deletes the graph from the vault', async ({ page }) => {
  await openGraph(page)
  await saveRepository(page, repository('widget'))
  await page.getByRole('tab', { name: 'Manage' }).click()
  const card = page.getByRole('region', { name: 'Delete this graph' })
  await card.getByRole('button', { name: 'Delete the graph…' }).click()
  await card.getByRole('button', { name: 'Yes, delete the graph' }).click()
  await expect(card.getByRole('status')).toBeVisible()
  expect(existsSync(join(vault, 'synapse', 'widget@main'))).toBe(false)
})

test('a checkout of another branch is not used to delete a graph', async ({ page }) => {
  await openGraph(page)
  await saveRepository(page, repository('other'))
  await page.getByRole('tab', { name: 'Manage' }).click()
  const card = page.getByRole('region', { name: 'Delete this graph' })
  await card.getByRole('button', { name: 'Delete the graph…' }).click()
  await expect(card.getByRole('alert')).toContainText('would delete another graph')
  expect(existsSync(join(vault, 'synapse', 'widget@main', 'Rendering.md'))).toBe(true)
})

test('cleaning up says when there is nothing to clean', async ({ page }) => {
  await openGraph(page)
  await saveRepository(page, repository('widget'))
  await page.getByRole('tab', { name: 'Manage' }).click()
  const card = page.getByRole('region', { name: 'Clean up deleted branches' })
  await card.getByRole('button', { name: 'Look for graphs to clean up…' }).click()
  await expect(card).toContainText('Nothing to clean up')
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
})

test('a rebuild asks first, then opens the default harness in the repository with the command', async ({
  page,
}) => {
  const repo = repository('widget')
  await openGraph(page)
  await saveRepository(page, repo)
  await page.getByRole('tab', { name: 'Manage' }).click()
  await page.getByRole('combobox', { name: 'Harness for the rebuild' }).selectOption('Claude')

  const card = page.getByRole('region', { name: 'Rebuild', exact: true })
  await card.getByRole('button', { name: 'Rebuild what changed…' }).click()
  const question = card.getByRole('alertdialog')
  await expect(question).toContainText('Are you sure?')
  await expect(question).toContainText("uses Claude Code's credits")
  await question.getByRole('button', { name: 'Cancel' }).click()
  await expect(page.getByRole('tab', { name: /Claude Code 1/ })).toHaveCount(0)

  await card.getByRole('button', { name: 'Rebuild what changed…' }).click()
  await card.getByRole('button', { name: 'Yes, open Claude Code' }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1 · rebuild' })).toBeVisible()
  // The stub harness prints what it was started with, and where.
  const screen = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await expect(screen).toContainText('/synapse-rebuild-diff')
  await expect(screen).toContainText(`cwd: ${repo}`)
})

test('a rebuild from scratch gives the full command, and the harness can be chosen', async ({
  page,
}) => {
  const repo = repository('widget')
  await openGraph(page)
  await saveRepository(page, repo)
  await page.getByRole('tab', { name: 'Manage' }).click()
  await page.getByRole('combobox', { name: 'Harness for the rebuild' }).selectOption('Codex')
  const card = page.getByRole('region', { name: 'Rebuild', exact: true })
  await card.getByRole('button', { name: 'Rebuild from scratch…' }).click()
  await expect(card.getByRole('alertdialog')).toContainText('deletes the graph of widget@main')
  await card.getByRole('button', { name: 'Yes, open Codex' }).click()
  await expect(page.getByRole('tab', { name: 'Codex 1 · rebuild all' })).toBeVisible()
  await expect(page.locator('.terminal-view:not([hidden]) .terminal-host')).toContainText(
    '$synapse-rebuild-full',
  )
})

test('a rebuild is not started from a checkout of another branch', async ({ page }) => {
  await openGraph(page)
  await saveRepository(page, repository('other'))
  await page.getByRole('tab', { name: 'Manage' }).click()
  const card = page.getByRole('region', { name: 'Rebuild', exact: true })
  await card.getByRole('button', { name: 'Rebuild what changed…' }).click()
  await card.getByRole('button', { name: /^Yes, open/ }).click()
  await expect(card.getByRole('alert')).toContainText('would build another graph')
  await expect(page.getByRole('tab', { name: /rebuild/ })).toHaveCount(0)
})

async function checkNewGraph(page: Page, path: string) {
  await page.getByRole('button', { name: 'New graph…' }).click()
  const card = page.getByRole('region', { name: 'New graph' })
  await card.getByRole('textbox', { name: 'Folder of the repository to build from' }).fill(path)
  await card.getByRole('button', { name: 'Check' }).click()
  return card
}

test('a new graph is built from a repository folder, after asking, and the folder is kept', async ({
  page,
}) => {
  const repo = repository('gadget')
  await openGraph(page)
  const card = await checkNewGraph(page, repo)
  const question = card.getByRole('alertdialog')
  await expect(question).toContainText('Are you sure?')
  await expect(question).toContainText('first graph of gadget@main')
  await expect(question).toContainText(repo)

  await question.getByRole('button', { name: 'Yes, open Claude Code' }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1 · build' })).toBeVisible()
  const screen = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await expect(screen).toContainText('/synapse-init')
  await expect(screen).toContainText(`cwd: ${repo}`)

  // The folder is saved for the namespace, so the graph can be checked once it is built.
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  const stored = JSON.parse(
    readFileSync(join(world().xdg, 'synapse-desktop', 'config.json'), 'utf8'),
  ) as { graphRepos: Record<string, string> }
  expect(stored.graphRepos['gadget@main']).toBe(repo)
})

test('a new graph for a namespace that has one points to the graph instead', async ({ page }) => {
  await openGraph(page)
  const card = await checkNewGraph(page, repository('widget'))
  await expect(card).toContainText('widget@main already has a graph')
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
  await card.getByRole('button', { name: 'Open it' }).click()
  await expect(page.getByLabel('Namespace', { exact: true })).toHaveValue('widget@main')
  await expect(page.getByRole('region', { name: 'New graph' })).toHaveCount(0)
})

test('a folder that is not a repository cannot start a new graph', async ({ page }) => {
  await openGraph(page)
  const card = await checkNewGraph(page, join(world().root, 'not-there'))
  await expect(card.getByRole('alert')).toBeVisible()
  await expect(card.getByRole('alertdialog')).toHaveCount(0)
})

test('a repository folder typed with ~ is the folder in the home folder, and is saved as that', async ({
  page,
}) => {
  const path = repository('widget', world().home)
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill('~/widget')
  await page.getByRole('button', { name: 'Save' }).click()
  const row = page.getByLabel('Repository', { exact: true })
  await expect(row).toContainText(path)
  await expect(row).toContainText('on widget@main')
  const stored = JSON.parse(
    readFileSync(join(world().xdg, 'synapse-desktop', 'config.json'), 'utf8'),
  ) as { graphRepos: Record<string, string> }
  expect(stored.graphRepos['widget@main']).toBe(path)
})

test('New graph takes a folder typed with ~, and opens the harness in the folder it is', async ({
  page,
}) => {
  const path = repository('gadget', world().home)
  await openGraph(page)
  const card = await checkNewGraph(page, '~/gadget')
  await expect(card.getByRole('alertdialog')).toContainText('first graph of gadget@main')
  await card.getByRole('button', { name: /^Yes, open/ }).click()
  await expect(page.locator('.terminal-view:not([hidden]) .terminal-host')).toContainText(
    `cwd: ${path}`,
  )
})

test('a saved folder on another branch is offered the checkout that is on the graph', async ({
  page,
}) => {
  const right = repository('widget')
  await openGraph(page)
  await saveRepository(page, repository('other'))
  const found = page.getByLabel('Checkouts found')
  await expect(found).toContainText('A checkout of widget@main found:')
  await expect(found).toContainText(right)
  // The folder that is saved is never offered again.
  await expect(found).not.toContainText(join(world().root, 'repos', 'other'))

  await found.getByRole('button', { name: 'Use it' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('on widget@main')
  await expect(page.getByLabel('Checkouts found')).toHaveCount(0)
})

test('a graph with no folder is offered the checkouts next to the ones saved for others', async ({
  page,
}) => {
  const widget = repository('widget')
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('thin@main')
  await page.getByRole('textbox', { name: 'Repository folder' }).fill(repository('thin'))
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('thin@main')

  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  const found = page.getByLabel('Checkouts found')
  await expect(found).toContainText(widget)
  await found.getByRole('button', { name: 'Use it' }).click()
  await expect(page.getByLabel('Repository', { exact: true })).toContainText('on widget@main')
})

test('nothing is offered when no folder has been saved to look next to', async ({ page }) => {
  repository('widget')
  await openGraph(page)
  await page.getByLabel('Namespace', { exact: true }).selectOption('widget@main')
  await expect(page.getByRole('textbox', { name: 'Repository folder' })).toBeVisible()
  await expect(page.getByLabel('Checkouts found')).toHaveCount(0)
})
