import { execFileSync, spawnSync } from 'node:child_process'
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Locator, Page } from '@playwright/test'
import { expect, test } from './fixtures.ts'
import {
  openCard,
  openSection,
  setEditorText,
  sidePanel,
  startRunWithoutTerminal,
  world,
} from './helpers.ts'

test('a run without a terminal is followed on its page to its end', async ({ page }) => {
  // The page of the execution, which goes through the loop once.
  await startRunWithoutTerminal(page, 'Develop_Feature')
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({
    timeout: 30_000,
  })
  await openCard(page, 'Trace')
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

test('a run started with a name shows the name', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Held_Run', exact: true }).click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel('Name (optional)').fill('  Fix login  ')
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()

  // The run starts in a terminal; once it has an id the page's title is the name, and the id is
  // under it.
  await expect(page.locator('h1.page-title')).toHaveText('Fix login', { timeout: 30_000 })
  const id = (await page.locator('.page-head p.mono').innerText()).trim()

  // The engine recorded the name of the run the dialog started, trimmed.
  const info = spawnSync('synapse-pipeline', ['info', id], {
    encoding: 'utf8',
    env: { ...process.env, XDG_CONFIG_HOME: world().xdg, SYNAPSE_WORK_DIR: world().work },
  })
  expect(info.stderr).toBe('')
  expect(info.stdout).toMatch(/^name {7}Fix login$/m)

  // The run's row in the sidebar and its tab are labelled with its name.
  await expect(sidePanel(page).locator('.list-row', { hasText: 'Fix login' }).first()).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Fix login', exact: true })).toBeVisible()

  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
})

// Starts a run of Develop_Feature without a terminal and waits for it to complete; returns its id.
async function runToCompletion(page: Page): Promise<string> {
  const id = await startRunWithoutTerminal(page, 'Develop_Feature')
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({ timeout: 30_000 })
  return id
}

// The sidebar row of a run, found by its execution id.
function runRow(page: Page, id: string) {
  return sidePanel(page).locator(`.list-row[data-execution="${id}"]`)
}

test('an unnamed run is labelled with its pipeline and start time', async ({ page }) => {
  const id = await runToCompletion(page)
  const row = runRow(page, id)
  await expect(row.locator('.list-name')).toHaveText('Develop_Feature')
  await expect(row.locator('.list-note')).toContainText(/^\d{1,2} \w{3} \d{2}:\d{2}/)
})

test('a finished run is deleted from its row', async ({ page }) => {
  const id = await runToCompletion(page)
  const tab = await page.locator('.tabbar .tab[data-selected="true"] [role="tab"]').innerText()
  const row = runRow(page, id)
  let asked = ''
  page.once('dialog', (d) => {
    asked = d.message()
    void d.accept()
  })
  await row.getByRole('button', { name: 'Delete this run' }).click()

  await expect(row).toHaveCount(0)
  await expect(page.getByRole('tab', { name: tab, exact: true })).toHaveCount(0)
  expect(asked).toContain('Delete the record of this run?')
  expect(existsSync(join(world().work, 'pipelines', id))).toBe(false)
})

// What `synapse-pipeline list --all` prints in this test's world.
function listAll(): string {
  const list = spawnSync('synapse-pipeline', ['list', '--all'], {
    encoding: 'utf8',
    env: { ...process.env, XDG_CONFIG_HOME: world().xdg, SYNAPSE_WORK_DIR: world().work },
  })
  expect(list.stderr).toBe('')
  return list.stdout
}

test('a run is renamed from its page', async ({ page }) => {
  const id = await runToCompletion(page)
  await page.getByRole('button', { name: 'Rename this run' }).click()
  const field = page.getByLabel('Name of this run')
  await expect(field).toHaveValue('')
  await field.fill('Second try')
  await field.press('Enter')

  await expect(page.locator('h1.page-title')).toHaveText('Second try')
  await expect(page.locator('.page-head p.mono')).toHaveText(id)
  await expect(runRow(page, id).locator('.list-name')).toHaveText('Second try')
  const line = listAll()
    .split('\n')
    .find((one) => one.startsWith(id))
  expect(line).toMatch(new RegExp(`^${id}\\s+Second try\\s+Develop_Feature`))
})

test('Escape cancels a rename', async ({ page }) => {
  const id = await runToCompletion(page)
  await page.getByRole('button', { name: 'Rename this run' }).click()
  const field = page.getByLabel('Name of this run')
  await field.fill('Not kept')
  await field.press('Escape')

  await expect(field).toHaveCount(0)
  await expect(page.locator('h1.page-title')).toHaveText(id)
  expect(existsSync(join(world().work, 'pipelines', id, 'name'))).toBe(false)
})

test('a finished run is deleted from its page', async ({ page }) => {
  const id = await runToCompletion(page)
  const tab = await page.locator('.tabbar .tab[data-selected="true"] [role="tab"]').innerText()
  let asked = ''
  page.once('dialog', (d) => {
    asked = d.message()
    void d.accept()
  })
  await page.locator('.head-actions').getByRole('button', { name: 'Delete', exact: true }).click()

  await expect(page.getByRole('tab', { name: tab, exact: true })).toHaveCount(0)
  await expect(runRow(page, id)).toHaveCount(0)
  expect(asked).toContain('Delete the record of this run?')
  expect(existsSync(join(world().work, 'pipelines', id))).toBe(false)
})

test("a running run's row has no delete button", async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Held_Run', exact: true }).click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()
  await expect(page.getByText('Execution', { exact: true })).toBeVisible({ timeout: 30_000 })
  const id = (await page.getByRole('heading', { level: 1 }).innerText()).trim()

  const row = runRow(page, id)
  await expect(row.getByText('running', { exact: true })).toBeVisible({ timeout: 30_000 })
  await expect(row.getByRole('button', { name: 'Delete this run' })).toHaveCount(0)
  // A finished run's row beside it has one.
  await expect(
    runRow(page, 'exec-fixture1').getByRole('button', { name: 'Delete this run' }),
  ).toHaveCount(1)

  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
})

test('several runs are deleted in selection mode', async ({ page }) => {
  const first = await runToCompletion(page)
  const second = await runToCompletion(page)
  const selectedTab = page.locator('.tabbar .tab[data-selected="true"] [role="tab"]')
  const secondTab = await selectedTab.innerText()
  // Both runs' pages are open.
  await runRow(page, first).locator('.list-item').click()
  await expect(page.locator('h1.page-title')).toHaveText(first)
  const firstTab = await selectedTab.innerText()
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'Select', exact: true }).click()
  await runRow(page, first).getByRole('checkbox').check()
  // Clicking a row ticks it rather than opening its page.
  await runRow(page, second).locator('.list-item').click()
  await expect(runRow(page, second).getByRole('checkbox')).toBeChecked()
  await expect(panel.getByText('2 selected')).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Delete this run' })).toHaveCount(0)
  let asked = ''
  page.once('dialog', (d) => {
    asked = d.message()
    void d.accept()
  })
  await panel.getByRole('button', { name: 'Delete 2' }).click()

  await expect(runRow(page, first)).toHaveCount(0)
  await expect(runRow(page, second)).toHaveCount(0)
  await expect(page.getByRole('tab', { name: firstTab, exact: true })).toHaveCount(0)
  await expect(page.getByRole('tab', { name: secondTab, exact: true })).toHaveCount(0)
  expect(asked).toContain('Delete the records of 2 runs?')
  expect(existsSync(join(world().work, 'pipelines', first))).toBe(false)
  expect(existsSync(join(world().work, 'pipelines', second))).toBe(false)
  // Selection mode is left.
  await expect(panel.getByRole('checkbox')).toHaveCount(0)
})

test('Select all leaves out a running run', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Held_Run', exact: true }).click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()
  await expect(page.getByText('Execution', { exact: true })).toBeVisible({ timeout: 30_000 })
  const id = (await page.getByRole('heading', { level: 1 }).innerText()).trim()
  const running = runRow(page, id)
  await expect(running.getByText('running', { exact: true })).toBeVisible({ timeout: 30_000 })

  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'Select', exact: true }).click()
  await panel.getByRole('button', { name: 'Select all' }).click()
  await expect(running.getByRole('checkbox')).toBeDisabled()
  await expect(running.getByRole('checkbox')).not.toBeChecked()
  await expect(runRow(page, 'exec-fixture1').getByRole('checkbox')).toBeChecked()
  const finished = await panel.getByRole('checkbox', { checked: true }).count()
  expect(finished).toBeGreaterThan(0)
  await expect(panel.getByText(`${finished} selected`)).toBeVisible()
  // Pressed again with every one ticked, it clears the selection.
  await panel.getByRole('button', { name: 'Select all' }).click()
  await expect(panel.getByText('0 selected')).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Delete 0' })).toBeDisabled()
  await panel.getByRole('button', { name: 'Cancel' }).click()

  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
})

test('Escape leaves selection mode and deletes nothing', async ({ page }) => {
  const id = await runToCompletion(page)
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'Select', exact: true }).click()
  await runRow(page, id).getByRole('checkbox').check()
  await expect(panel.getByText('1 selected')).toBeVisible()
  await page.keyboard.press('Escape')

  await expect(panel.getByRole('checkbox')).toHaveCount(0)
  await expect(panel.getByRole('button', { name: 'Select', exact: true })).toBeVisible()
  await expect(runRow(page, id)).toHaveCount(1)
  expect(existsSync(join(world().work, 'pipelines', id))).toBe(true)
})

// The world's finished fixture run, which later tests read, is put back as it was after a test that
// removes every run: its record and the refs that pin its snapshots.
function keepFixtureRun(): () => void {
  const id = 'exec-fixture1'
  const record = join(world().work, 'pipelines', id)
  const saved = mkdtempSync(join(tmpdir(), 'sd-fixture-run-'))
  cpSync(record, saved, { recursive: true, preserveTimestamps: true })
  const refs = execFileSync(
    'git',
    ['for-each-ref', '--format=%(refname) %(objectname)', `refs/synapse/runs/${id}/`],
    { cwd: world().project, encoding: 'utf8' },
  )
    .split('\n')
    .filter((line) => line !== '')
  return () => {
    rmSync(record, { recursive: true, force: true })
    cpSync(saved, record, { recursive: true, preserveTimestamps: true })
    for (const line of refs) {
      const [name, object] = line.split(' ')
      if (name === undefined || object === undefined) continue
      execFileSync('git', ['update-ref', name, object], { cwd: world().project })
    }
    rmSync(saved, { recursive: true, force: true })
  }
}

// Removes every run that is not running, as the engine does when asked to.
function removeEveryRun(): void {
  const cleanup = spawnSync('synapse-pipeline', ['cleanup', '--older-than', '0s'], {
    encoding: 'utf8',
    env: { ...process.env, XDG_CONFIG_HOME: world().xdg, SYNAPSE_WORK_DIR: world().work },
  })
  expect(cleanup.status, cleanup.stderr).toBe(0)
}

// The Clean up dialog, opened from the panel.
async function openCleanup(page: Page) {
  await sidePanel(page).getByRole('button', { name: 'Clean up', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Clean up runs' })
  await expect(dialog).toBeVisible()
  return dialog
}

test('clean up previews and removes every finished run', async ({ page }) => {
  const restore = keepFixtureRun()
  try {
    removeEveryRun()
    const first = await runToCompletion(page)
    const second = await runToCompletion(page)
    const dialog = await openCleanup(page)
    await dialog.getByRole('radio', { name: 'Every finished run' }).check()
    await expect(dialog).toContainText('An interrupted run is kept until it is 30 days old.')
    await expect(dialog.getByText('2 runs will be removed')).toBeVisible()
    await dialog.getByRole('button', { name: 'Remove', exact: true }).click()

    await expect(dialog).toHaveCount(0)
    // Closing the runs' tabs shows the pipeline's page, and the panel with it.
    await openSection(page, 'Executions')
    await expect(sidePanel(page).getByText(/No executions found/)).toBeVisible()
    expect(existsSync(join(world().work, 'pipelines', first))).toBe(false)
    expect(existsSync(join(world().work, 'pipelines', second))).toBe(false)
  } finally {
    restore()
  }
})

test('clean up with nothing old enough disables Remove', async ({ page }) => {
  const id = await runToCompletion(page)
  const dialog = await openCleanup(page)
  await dialog.getByRole('button', { name: '30 days', exact: true }).click()
  await expect(dialog.getByRole('radio', { name: /Older than/ })).toBeChecked()
  await expect(dialog.getByText('Nothing to remove.')).toBeVisible()
  await expect(dialog.getByRole('button', { name: 'Remove', exact: true })).toBeDisabled()
  await dialog.getByRole('button', { name: 'Cancel' }).click()
  await expect(dialog).toHaveCount(0)
  expect(existsSync(join(world().work, 'pipelines', id))).toBe(true)
})

test('a preset fills the days and is remembered', async ({ page }) => {
  // A finished run last written ten days ago.
  const id = 'exec-cleanup-old'
  const dir = join(world().work, 'pipelines', id)
  mkdirSync(dir, { recursive: true })
  const summary = join(dir, 'execution.json')
  const then = new Date(Date.now() - 10 * 24 * 3600 * 1000)
  writeFileSync(
    summary,
    JSON.stringify({
      format: 'synapse-pipeline-execution/v1',
      id,
      pipeline: 'Develop_Feature',
      started: then.toISOString(),
      ended: then.toISOString(),
      status: 'completed',
      current_step: null,
      state: { steps_run: 2 },
    }),
  )
  utimesSync(summary, then, then)
  try {
    await page.goto('/')
    await openSection(page, 'Executions')
    let dialog = await openCleanup(page)
    await dialog.getByRole('button', { name: '7 days', exact: true }).click()
    await expect(dialog.getByLabel('Days')).toHaveValue('7')
    await expect(dialog.getByText(/runs? will be removed/)).toBeVisible()
    await dialog.getByRole('button', { name: 'Remove', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    expect(existsSync(dir)).toBe(false)

    dialog = await openCleanup(page)
    await expect(dialog.getByLabel('Days')).toHaveValue('7')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a run works in the folder it was given', async ({ page }) => {
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
    await sidePanel(page).getByRole('button', { name: 'Held_Run', exact: true }).click()
    await page.getByRole('button', { name: 'Run', exact: true }).click()
    await page.getByLabel(/Folder its agents work in/).fill(dir)
    await page.getByRole('button', { name: 'Start run' }).click()
    await expect(page.getByText('Execution', { exact: true })).toBeVisible({ timeout: 30_000 })

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

    page.once('dialog', (d) => void d.accept())
    await page.getByRole('button', { name: 'Stop run' }).click()
    await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
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
  await expect(actions).toHaveCount(3)
  await expect(actions.nth(0)).toHaveAccessibleName('Run Develop_Feature')
  await expect(actions.nth(1)).toHaveAccessibleName('Clone Develop_Feature')
  await expect(actions.nth(2)).toHaveAccessibleName('Delete this pipeline')
  await row.getByRole('button', { name: 'Run Develop_Feature' }).click()

  const dialog = page.getByRole('dialog')
  await expect(dialog).toContainText('Run Develop_Feature')
  // The pipeline's page did not open behind the dialog.
  await expect(page.getByText('Pipeline', { exact: true })).toHaveCount(0)
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()

  await expect(page.getByText('Execution', { exact: true })).toBeVisible({ timeout: 30_000 })
  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
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
  await runRow(page, 'exec-fixture1').locator('.list-item').click()
  await openCard(page, 'Trace')
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

test('the outcomes come first, and the trace and events are folded until opened, on every run', async ({
  page,
}) => {
  const open = async () => {
    await openSection(page, 'Executions')
    await runRow(page, 'exec-fixture1').locator('.list-item').click()
    await expect(page.getByRole('heading', { level: 1, name: 'exec-fixture1' })).toBeVisible()
  }
  await page.goto('/')
  await open()

  // Below the summary come the definitions, then the outcomes, the trace and the events. The
  // definitions are read on their own and can show after the rest, so the order is asked again
  // until it settles.
  const cards = page.locator('.content section.card')
  await expect
    .poll(async () => {
      const labels = await cards.evaluateAll((all) => all.map((c) => c.getAttribute('aria-label')))
      return labels.slice(labels.indexOf('Summary') + 1)
    })
    .toEqual(['Definitions it ran', 'Outcomes', 'Trace', 'Events'])

  // The outcomes are open, the trace and the events folded, with how many rows each has.
  const fold = (name: string) => page.getByLabel(name, { exact: true }).locator('.card-fold')
  await expect(fold('Outcomes')).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByLabel('Outcomes').locator('.trace > div').first()).toBeVisible()
  await expect(fold('Trace')).toHaveText(/^Trace · \d+ visits?$/)
  await expect(fold('Events')).toHaveText(/^Events · \d+$/)
  await expect(fold('Trace')).toHaveAttribute('aria-expanded', 'false')
  await expect(fold('Events')).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByLabel('Trace').locator('.trace > div')).toHaveCount(0)
  await expect(page.getByLabel('Events').locator('.event')).toHaveCount(0)

  // The trace opens from the keyboard, and its rows have no link to the changes.
  await fold('Trace').focus()
  await page.keyboard.press('Enter')
  await expect(fold('Trace')).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByLabel('Trace').locator('.trace > div').first()).toBeVisible()
  await expect(
    page.getByLabel('Trace').getByRole('button', { name: 'Changes', exact: true }),
  ).toHaveCount(0)

  // The outcomes fold, and their rows go.
  await fold('Outcomes').click()
  await expect(fold('Outcomes')).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByLabel('Outcomes').locator('.trace > div')).toHaveCount(0)

  // The choice is kept for the next time a run is opened.
  await page.reload()
  await open()
  await expect(fold('Trace')).toHaveAttribute('aria-expanded', 'true')
  await expect(fold('Outcomes')).toHaveAttribute('aria-expanded', 'false')
})

test('an interactive run has its terminal on the page of the run', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: 'Fixture_Run', exact: true })
    .click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  // The dialog starts an interactive run; it has no choice of a run without a terminal.
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await expect(dialog.getByRole('checkbox')).toHaveCount(0)
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

// Opens the run dialog of a pipeline from the definitions list.
async function openRunDialog(page: Page, pipeline: string) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page)
    .getByRole('button', { name: `Run ${pipeline}` })
    .click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  return dialog
}

// Starts the run from an open run dialog, in a terminal, and checks the engine recorded the input
// the dialog started it with; then stops the run.
async function startAndCheckInput(page: Page, start: Locator, input: unknown) {
  await page
    .getByRole('dialog')
    .getByLabel(/Folder its agents work in/)
    .fill(world().root)
  await start.click()
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/^exec-/, { timeout: 30_000 })
  const id = (await page.getByRole('heading', { level: 1 }).innerText()).trim()
  const record = join(world().work, 'pipelines', id, 'execution.json')
  await expect
    .poll(() => {
      try {
        const kept = JSON.parse(readFileSync(record, 'utf8')) as {
          state: { initial_input: unknown }
        }
        return kept.state.initial_input
      } catch {
        return undefined
      }
    })
    .toEqual(input)
  page.once('dialog', (d) => void d.accept())
  await page.getByRole('button', { name: 'Stop run' }).click()
  await expect(page.getByRole('region', { name: 'Terminal', exact: true })).toHaveCount(0)
}

test('a pipeline with Input opens the JSON editor with a sample and a field reference and no Text tab', async ({
  page,
}) => {
  // Two required fields: a sentence cannot give them, so only the editor is offered.
  const dialog = await openRunDialog(page, 'Structured_Input')
  await expect(dialog.getByRole('tab')).toHaveCount(0)
  await expect(dialog.getByLabel('What should this pipeline work on?')).toHaveCount(0)
  const editor = dialog.getByLabel('Input as JSON')
  await expect(editor).toContainText('"task_id": ""')
  await expect(editor).toContainText('"attempts": 0')
  const fields = dialog.getByLabel('Fields of the input')
  await expect(fields).toContainText('task_id')
  await expect(fields).toContainText('string · required')
  await expect(fields).toContainText('The id of the task to work on.')
  await expect(fields).toContainText('attempts')
  await expect(fields).toContainText('integer · required')
})

// The JSON tab of the run dialog of Implement_With_Input, whose one required string field keeps the
// Text tab.
async function openJsonTab(page: Page) {
  const dialog = await openRunDialog(page, 'Implement_With_Input')
  await dialog.getByRole('tab', { name: 'JSON' }).click()
  const fields = dialog.getByLabel('Fields of the input')
  await expect(fields).toContainText('instructions')
  await expect(fields).toContainText('string · optional')
  return dialog
}

test('a missing required field shows the problem and Start run stays disabled', async ({
  page,
}) => {
  const dialog = await openJsonTab(page)
  const problems = dialog.getByRole('status', { name: 'Problems with the input' })
  // The sample's empty task id does not match the pattern.
  await expect(problems).toContainText('input.task_id: does not match required pattern')
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeDisabled()

  await setEditorText(page, '{"instructions": "keep it small"}', dialog.locator('.cm-content'))
  await expect(problems).toContainText('input.task_id: required field is missing')
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeDisabled()

  // Text that is not JSON is its own problem, and nothing is checked.
  await setEditorText(page, '{oops', dialog.locator('.cm-content'))
  await expect(problems).toContainText('The input is not valid JSON')
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeDisabled()
})

test('a valid input enables Start run and the run starts with it', async ({ page }) => {
  const dialog = await openJsonTab(page)
  await setEditorText(page, '{"task_id": "abc-1"}', dialog.locator('.cm-content'))
  const start = dialog.getByRole('button', { name: 'Start run' })
  await expect(start).toBeEnabled()
  await expect(dialog.getByRole('status', { name: 'Problems with the input' })).toHaveText('')
  await startAndCheckInput(page, start, { task_id: 'abc-1' })
})

test('JSON typed before switching to the Text tab and back is kept and starts the run', async ({
  page,
}) => {
  const dialog = await openJsonTab(page)
  await setEditorText(page, '{"task_id": "abc-2"}', dialog.locator('.cm-content'))
  await dialog.getByRole('tab', { name: 'Text' }).click()
  await dialog.getByRole('tab', { name: 'JSON' }).click()
  await expect(dialog.getByLabel('Input as JSON')).toHaveText('{"task_id": "abc-2"}')
  const start = dialog.getByRole('button', { name: 'Start run' })
  await expect(start).toBeEnabled()
  await startAndCheckInput(page, start, { task_id: 'abc-2' })
})

test('the prompt preview lists the fields with their descriptions', async ({ page }) => {
  const dialog = await openJsonTab(page)
  await setEditorText(page, '{"task_id": "abc-1"}', dialog.locator('.cm-content'))
  await dialog.getByText('The prompt of the first step, with this input').click()
  const prompt = dialog.locator('.prompt-added-text')
  await expect(prompt).toContainText('- task_id: abc-1')
  await expect(prompt).toContainText('The id of the task to implement, such as synapse-70.')
  await expect(prompt).toContainText('- instructions: (not given)')
})

test('a pipeline with one required string field keeps the Text tab', async ({ page }) => {
  const dialog = await openRunDialog(page, 'Text_Input')
  await expect(dialog.getByRole('tab', { name: 'Text' })).toBeVisible()
  await expect(dialog.getByRole('tab', { name: 'JSON' })).toBeVisible()
  await dialog.getByLabel('What should this pipeline work on?').fill('fix issue 7')
  // The sentence becomes the one required field, so it passes the check.
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeEnabled()
  await expect(dialog.getByRole('status', { name: 'Problems with the input' })).toHaveText('')

  // A required string next to optional fields is still given by a sentence.
  await dialog.getByRole('button', { name: 'Cancel' }).click()
  const other = await openRunDialog(page, 'Implement_With_Input')
  await expect(other.getByRole('tab', { name: 'Text' })).toBeVisible()
  await other.getByLabel('What should this pipeline work on?').fill('abc-1')
  await expect(other.getByRole('button', { name: 'Start run' })).toBeEnabled()
})

test('a pipeline without Input keeps both tabs and starts with {}', async ({ page }) => {
  const dialog = await openRunDialog(page, 'Develop_Feature')
  await expect(dialog.getByRole('tab', { name: 'Text' })).toBeVisible()
  await dialog.getByRole('tab', { name: 'JSON' }).click()
  await expect(dialog.getByLabel('Input as JSON')).toHaveText('{}')
  await expect(dialog.getByLabel('Fields of the input')).toHaveCount(0)
  await expect(dialog.getByRole('button', { name: 'Start run' })).toBeEnabled()
})
