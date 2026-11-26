import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from './fixtures.ts'
import { openSection, sidePanel, world } from './helpers.ts'

test('a run is started from a pipeline and followed to its end', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: 'Develop_Feature', exact: true })
    .click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  // The box is ticked and disabled until the pipeline is checked, so wait for it to be free.
  await expect(page.getByLabel(/Run without a terminal/)).toBeEnabled()
  // The folder is asked for whether the run has a terminal or not.
  const folder = page.getByLabel(/Folder its agents work in/)
  await expect(folder).toBeVisible()
  await page.getByLabel(/Run without a terminal/).check()
  await expect(folder).toBeVisible()
  await page.getByRole('button', { name: 'Start run' }).click()

  // The page of the execution, which goes through the loop once.
  await expect(page.getByText('Execution', { exact: true })).toBeVisible()
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({
    timeout: 30_000,
  })
  const trace = page.getByLabel('Trace')
  await expect(trace).toContainText('Changes_Requested → Develop')
  await expect(trace).toContainText('Approved → the run completes')
  // A scripted run has no session, and says so.
  await expect(trace.getByText('no transcript').first()).toBeVisible()

  // What each visit reported: the newest is open, the others open on a click.
  const outcomes = page.getByLabel('Outcomes')
  const rows = outcomes.locator('.trace > div')
  await expect(rows).toHaveCount(6)
  const approved = rows.nth(5)
  await expect(approved).toContainText('Approved → the run completes')
  await expect(approved.getByRole('button', { name: 'Hide outcome' })).toHaveAttribute(
    'aria-expanded',
    'true',
  )
  await expect(approved).toContainText('looks good')
  await expect(approved.getByRole('button', { name: 'Copy JSON' })).toBeVisible()

  const requested = rows.nth(2)
  await expect(requested).toContainText('Changes_Requested → Develop')
  await expect(requested.getByLabel('Problems')).toHaveCount(0)
  await requested.getByRole('button', { name: 'Outcome', exact: true }).click()
  const problems = requested.getByLabel('Problems')
  await expect(problems).toContainText('a.txt')
  await expect(problems).toContainText('one issue')
  // The data, as a tree: its first level is open, the entry below it folded.
  await expect(requested.locator('.json-tree')).toContainText('problems:')
  await expect(requested.locator('.json-tree')).toContainText('{ 3 }')
})

test('a run without a terminal works in the folder it was given', async ({ page }) => {
  const dir = mkdtempSync(join(tmpdir(), 'sd-run-folder-'))
  const git = (...args: string[]) =>
    execFileSync('git', ['-c', 'user.name=A', '-c', 'user.email=a@example.com', ...args], {
      cwd: dir,
    })
  try {
    git('init', '-q')
    writeFileSync(join(dir, 'a.txt'), 'one\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'first')

    await page.goto('/')
    await openSection(page, 'Definitions')
    await sidePanel(page).getByRole('button', { name: 'Develop_Feature', exact: true }).click()
    await page.getByRole('button', { name: 'Run', exact: true }).click()
    await expect(page.getByLabel(/Run without a terminal/)).toBeEnabled()
    await page.getByLabel(/Run without a terminal/).check()
    await page.getByLabel(/Folder its agents work in/).fill(dir)
    await page.getByRole('button', { name: 'Start run' }).click()
    await expect(
      page.locator('.content').getByText('completed', { exact: true }).first(),
    ).toBeVisible({ timeout: 30_000 })

    // The record of the run says it worked in that folder. `info` does not print the folder;
    // `changes` does, as the Changes sidebar reads it.
    const id = await page.getByRole('heading', { level: 1 }).innerText()
    const brief = JSON.parse(
      execFileSync('synapse-pipeline', ['changes', id.trim(), '--format', 'json'], {
        encoding: 'utf8',
      }),
    ) as { directory: string | null }
    expect(brief.directory).not.toBeNull()
    expect(realpathSync(brief.directory!)).toBe(realpathSync(dir))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a run is started from the definitions list without the pipeline's page", async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  const row = sidePanel(page).locator('.list-entry', { hasText: 'Develop_Feature' })
  // Play comes before the bin, so keyboard focus reaches it first.
  const actions = row.locator('.list-action')
  await expect(actions).toHaveCount(2)
  await expect(actions.nth(0)).toHaveAccessibleName('Run Develop_Feature')
  await expect(actions.nth(1)).toHaveAccessibleName('Delete this pipeline')
  await row.getByRole('button', { name: 'Run Develop_Feature' }).click()

  const dialog = page.getByRole('dialog')
  await expect(dialog).toContainText('Run Develop_Feature')
  // The pipeline's page did not open behind the dialog.
  await expect(page.getByText('Pipeline', { exact: true })).toHaveCount(0)
  await expect(dialog.getByLabel(/Run without a terminal/)).toBeEnabled()
  await dialog.getByLabel(/Run without a terminal/).check()
  await dialog.getByRole('button', { name: 'Start run' }).click()

  await expect(page.getByText('Execution', { exact: true })).toBeVisible()
})

test('only pipelines have a run button in the list', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Agents' }).click()
  const row = sidePanel(page).locator('.list-entry', { hasText: 'Reviewer' }).first()
  await expect(row.getByRole('button', { name: 'Delete this agent' })).toBeVisible()
  await expect(row.getByRole('button', { name: /^Run / })).toHaveCount(0)
})

test('what an agent did in a step is read from its transcript', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Executions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: /exec-fixture1/ })
    .click()
  await page.getByRole('button', { name: 'Activity' }).click()

  const activity = page.getByLabel('Trace')
  await expect(activity).toContainText('Claude · 3 turns · 5.0 s · $0.12')
  await expect(activity.getByLabel('Files changed')).toContainText('+ result.txt')
  // Each action is a title and what it was done to, with paths shown without
  // the folder the session worked in.
  const actions = activity.locator('.activity-row')
  await expect(actions).toHaveCount(4)
  await expect(actions.nth(0)).toContainText('Read')
  await expect(actions.nth(0).locator('.activity-target')).toHaveText('notes.txt')
  await expect(actions.nth(1)).toContainText('Wrote')
  await expect(actions.nth(1).locator('.activity-target')).toHaveText('result.txt')
  await expect(actions.nth(2).locator('.activity-target')).toHaveText('ls')
  await expect(actions.nth(3)).toContainText('Wrote the word.')
  await page.getByRole('button', { name: 'Hide activity' }).click()
  await expect(actions).toHaveCount(0)
})

test('an interactive run has its terminal on the page of the run', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: 'Fixture_Run', exact: true })
    .click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  // The dialog starts an interactive run, without the box touched.
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()

  // The page of the run, with its terminal in a card under the graph, open.
  await expect(page.getByText('Execution', { exact: true })).toBeVisible({ timeout: 30_000 })
  const card = page.getByRole('region', { name: 'Terminal', exact: true })
  const toggle = card.getByRole('button', { name: 'Hide terminal' })
  await expect(toggle).toHaveAttribute('aria-expanded', 'true')
  const screen = card.locator('.terminal-host')
  await expect(screen).toContainText('cwd: ', { timeout: 30_000 })
  const graph = await page.getByRole('region', { name: 'Run graph' }).boundingBox()
  const terminal = await card.boundingBox()
  expect(graph).not.toBeNull()
  expect(terminal).not.toBeNull()
  expect(terminal!.y).toBeGreaterThan(graph!.y)
  // The run has no tab on the Terminals page.
  await expect(page.getByRole('tab', { name: 'Terminals' })).toHaveCount(0)

  // Collapsed, the card hides the terminal, and opened it is there again.
  await toggle.click()
  const show = card.getByRole('button', { name: 'Show terminal' })
  await expect(show).toHaveAttribute('aria-expanded', 'false')
  await expect(screen).toBeHidden()
  await show.click()
  await expect(screen).toBeVisible()
  await expect(screen).toContainText('cwd: ')

  // Away to Home and back, the screen is drawn again.
  const runTab = page.locator('.tabbar .tab[data-selected="true"] [role="tab"]')
  const name = await runTab.innerText()
  await page.getByRole('tab', { name: 'Home' }).click()
  await page.getByRole('tab', { name }).click()
  await expect(
    page.getByRole('region', { name: 'Terminal', exact: true }).locator('.terminal-host'),
  ).toContainText('cwd: ', { timeout: 30_000 })

  // The run is stopped from its page; its terminal goes with it.
  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
})
