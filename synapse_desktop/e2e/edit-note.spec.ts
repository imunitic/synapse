import { expect, test, type Page } from './fixtures.ts'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

const TARGET =
  '---\ntitle: Target\nupdated: 2026-01-01T00:00:00+00:00\n---\n# Target\n\nFirst line.\n'
const OTHER =
  '---\ntitle: Other\nupdated: 2026-01-01T00:00:00+00:00\n---\n# Other\n\nAnother note.\n'

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'edit-note-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  mkdirSync(join(vault, 'synapse', 'widget@main'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(join(vault, 'research', 'Target.md'), TARGET)
  writeFileSync(join(vault, 'research', 'Other.md'), OTHER)
  writeFileSync(
    join(vault, 'synapse', 'widget@main', 'Node.md'),
    '---\ntitle: Node\n---\nA node.\n',
  )
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

async function openTarget(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'research' }).click()
  await panel.getByRole('button', { name: 'Target' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Target' })).toBeVisible()
}

async function change(page: Page, description: string) {
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  await page.getByLabel('What should change?').fill(description)
  await page.getByRole('button', { name: 'Change the note' }).click()
}

test('a note has a pencil that opens a box to describe the change, and a node of a code graph has none', async ({
  page,
}) => {
  await openTarget(page)
  const pencil = page.getByRole('button', { name: 'Edit with an agent' })
  await expect(pencil).toBeVisible()
  await pencil.click()
  await expect(page.getByLabel('What should change?')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Change the note' })).toBeDisabled()
  await expect(page.getByText('It is told to change only this note.')).toBeVisible()
  await pencil.click()
  await expect(page.getByLabel('What should change?')).toHaveCount(0)

  // A node of a code graph is opened from the graph, and is not for an agent to change.
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await page.evaluate(() => undefined)
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'synapse' }).click()
  await panel.getByRole('button', { name: 'widget@main' }).click()
  await panel.getByRole('button', { name: 'Node' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Node' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Edit with an agent' })).toHaveCount(0)
})

test('the box opens under the title, and Cancel closes it and forgets what was typed', async ({
  page,
}) => {
  await openTarget(page)
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  const box = page.getByRole('region', { name: 'Change this note with an agent' })
  await expect(box).toBeVisible()
  const title = await page.getByRole('heading', { level: 1, name: 'Target' }).boundingBox()
  const opened = await box.boundingBox()
  // Under the title and not beside it.
  expect(opened!.y).toBeGreaterThanOrEqual(title!.y + title!.height - 1)

  await page.getByLabel('What should change?').fill('Something I then think better of')
  await box.getByRole('button', { name: 'Cancel' }).click()
  await expect(box).toHaveCount(0)
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  await expect(page.getByLabel('What should change?')).toHaveValue('')
})

test('the agent changes the note, which is read again, and what it did is shown', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line about the change')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed: 2 lines added and 0 removed.')
  await expect(page.locator('.note-body')).toContainText('Stub edit: Add a line about the change')
  // The box closes and is empty for the next change.
  await expect(page.getByLabel('What should change?')).toHaveCount(0)

  await result.getByText('Show what changed').click()
  const diff = result.getByLabel('The lines that changed')
  await expect(diff).toContainText('+ Stub edit: Add a line about the change')
  await expect(result).not.toContainText('also moved')
})

test('undo puts the note back as it was', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line to undo')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toContain('Stub edit')

  await result.getByRole('button', { name: 'Undo' }).click()
  await expect(result).toContainText('The note is put back as it was.')
  await expect(result.getByRole('button', { name: 'Undo' })).toHaveCount(0)
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
  await expect(page.getByText('Stub edit')).toHaveCount(0)
})

test('undo is refused, and nothing is written, when the note was changed again', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  const changedByHand = `${readFileSync(join(vault, 'research', 'Target.md'), 'utf8')}\nA line by hand.\n`
  writeFileSync(join(vault, 'research', 'Target.md'), changedByHand)

  await result.getByRole('button', { name: 'Undo' }).click()
  await expect(result.getByRole('alert')).toContainText('The note was changed again since')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(changedByHand)
  // It can be tried again, since the note is still as the change left it, apart from the line.
  await expect(result.getByRole('button', { name: 'Undo' })).toBeEnabled()
})

test('says so when another note moved, which the agent was told not to touch', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line and TOUCHOTHER')
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result.getByRole('alert')).toContainText('research/Other.md')
  await expect(result.getByRole('alert')).toContainText('which it was told not to')
})

test('says why when the note was not changed, and keeps the box and what was typed', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'FAILCASE please')
  await expect(page.getByRole('alert')).toContainText('The note was not changed.')
  await expect(page.getByRole('alert')).toContainText('the stub was asked to fail')
  await expect(page.getByLabel('What should change?')).toHaveValue('FAILCASE please')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)

  await page.getByLabel('What should change?').fill('NOCHANGE')
  await page.getByRole('button', { name: 'Change the note' }).click()
  await expect(page.getByRole('alert')).toContainText('The note was not changed.')
})

// The line that shows the agent at work, which the Result card's own status is not.
const workingLine = (page: Page, doing = 'changing the note') =>
  page.getByRole('status').filter({ hasText: `is ${doing}` })

// The harness the app keeps as the default, which is what changes the note.
function useDefaultHarness(harness: string) {
  const file = join(world().xdg, 'synapse-desktop', 'config.json')
  const stored = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>
  writeFileSync(file, JSON.stringify({ ...stored, defaultHarness: harness }))
}

test('while the agent works a line shows who, for how long and what it does, and the activity can be listed', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line, SLOWCASE')
  const line = workingLine(page)
  await expect(line).toContainText('Claude Code is changing the note')
  await expect(line).toContainText('Running synapse vault-read research/Target.md')
  // The time ticks.
  await expect(line).toContainText(/· 0:0[2-9]/)
  await expect(page.getByRole('button', { name: 'Changing…' })).toBeDisabled()

  await page.getByRole('button', { name: 'Show activity' }).click()
  await expect(page.getByText('synapse vault-read research/Target.md').last()).toBeVisible()
  await page.getByRole('button', { name: 'Hide activity' }).click()
  await expect(page.getByRole('button', { name: 'Show activity' })).toBeVisible()
})

test('a finished run takes the working line away and shows the result', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line')
  await expect(page.getByRole('region', { name: 'What the change did' })).toContainText(
    'The note is changed',
  )
  await expect(workingLine(page)).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Show activity' })).toHaveCount(0)
})

test('Stop ends the run, and says so when the note was not changed', async ({ page }) => {
  await openTarget(page)
  await change(page, 'Add a line, SLOWCASE')
  await expect(workingLine(page)).toContainText('Running synapse vault-read')
  await page.getByRole('button', { name: 'Stop' }).click()
  await expect(page.getByRole('alert')).toContainText(
    'The run was stopped and the note was not changed.',
  )
  await expect(workingLine(page)).toHaveCount(0)
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
  await expect(page.getByLabel('What should change?')).toHaveValue('Add a line, SLOWCASE')
})

test('a run that is stopped after the note changed shows the result, which can be undone', async ({
  page,
}) => {
  await openTarget(page)
  await change(page, 'Add a line, SLOWCASE')
  await expect(workingLine(page)).toContainText('Running synapse vault-read')
  // What the agent had written before it was stopped.
  const changed = `${TARGET}\nA line it wrote.\n`
  writeFileSync(join(vault, 'research', 'Target.md'), changed)
  await page.getByRole('button', { name: 'Stop' }).click()
  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  await result.getByRole('button', { name: 'Undo' }).click()
  await expect(result).toContainText('The note is put back as it was.')
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
})

for (const [harness, label] of [
  ['Codex', 'Codex'],
  ['Opencode', 'OpenCode'],
] as const) {
  test(`with ${label} the line shows the harness and the time, and no action`, async ({ page }) => {
    useDefaultHarness(harness)
    await openTarget(page)
    await change(page, 'Add a line, SLOWCASE')
    const line = workingLine(page)
    await expect(line).toContainText(`${label} is changing the note`)
    await expect(line).toContainText(/· 0:0[2-9]/)
    await expect(line.locator('.working-action')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Show activity' })).toHaveCount(0)
    await page.getByRole('button', { name: 'Stop' }).click()
    await expect(page.getByRole('alert')).toContainText('The run was stopped')
  })
}

test.describe('in a wide window', () => {
  test.use({ viewport: { width: 1600, height: 900 } })

  const bodyWidth = (page: Page): Promise<number> =>
    page.locator('.note-body').evaluate((element) => element.getBoundingClientRect().width)

  test('a note is narrow until its Wide switch is on, and the choice is its own and kept', async ({
    page,
  }) => {
    await openTarget(page)
    const wide = page.getByRole('switch', { name: 'Wide note' })
    await expect(wide).toHaveAttribute('aria-checked', 'false')
    const narrow = await bodyWidth(page)

    await wide.click()
    await expect(wide).toHaveAttribute('aria-checked', 'true')
    expect(await bodyWidth(page)).toBeGreaterThan(narrow + 200)

    // Another note keeps its own choice, which is narrow.
    await sidePanel(page).getByRole('button', { name: 'Other' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Other' })).toBeVisible()
    await expect(page.getByRole('switch', { name: 'Wide note' })).toHaveAttribute(
      'aria-checked',
      'false',
    )
    expect(await bodyWidth(page)).toBe(narrow)

    // The note that was widened is still wide after a reload.
    await page.reload()
    await openTarget(page)
    await expect(page.getByRole('switch', { name: 'Wide note' })).toHaveAttribute(
      'aria-checked',
      'true',
    )
    expect(await bodyWidth(page)).toBeGreaterThan(narrow + 200)

    await page.getByRole('switch', { name: 'Wide note' }).click()
    expect(await bodyWidth(page)).toBe(narrow)
  })
})
