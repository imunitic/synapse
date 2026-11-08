import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

// What the background runs of the stub harnesses were given, a line for each.
const logFile = () => join(world().root, 'stub-args.log')
// An entry can run to many lines, since an argument can be a long text, so entries are told
// apart by the program that starts each.
const runs = (): string[] =>
  existsSync(logFile())
    ? readFileSync(logFile(), 'utf8')
        .trim()
        .split(/\n(?=(?:claude|codex|opencode) )/)
    : []

test.beforeEach(() => {
  resetWorldSettings()
  rmSync(logFile(), { force: true })
  vault = join(world().root, 'run-model-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  rmSync(logFile(), { force: true })
  resetWorldSettings()
})

async function openNewNote(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'New note' })).toBeVisible()
}

// What the app has kept as the default model of each harness, from its configuration file.
const keptModels = (): Record<string, string> =>
  (
    JSON.parse(readFileSync(join(world().xdg, 'synapse-desktop', 'config.json'), 'utf8')) as {
      defaultModels?: Record<string, string>
    }
  ).defaultModels ?? {}

const model = (page: Page) => page.getByRole('combobox', { name: 'Model for this run' })
const harness = (page: Page) => page.getByLabel('Harness for this run')

async function choose(page: Page, name: string) {
  await model(page).click()
  // A model may be followed by what its harness says of it, so the option holds the name.
  await page.getByRole('listbox').getByRole('option').filter({ hasText: name }).first().click()
  await expect(model(page)).toHaveValue(name)
}

async function writeNote(page: Page) {
  await page.getByLabel('Describe the note').fill('A note for the model test')
  await page.getByRole('button', { name: 'Write the note' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Stub note' })).toBeVisible()
}

test('a note is written with the model chosen for it', async ({ page }) => {
  await openNewNote(page)
  await choose(page, 'opus')
  await writeNote(page)
  expect(runs()).toHaveLength(1)
  expect(runs()[0]).toContain('--model opus')
})

test('a note is written without a model flag when none is chosen anywhere', async ({ page }) => {
  await openNewNote(page)
  await expect(model(page)).toHaveAttribute('placeholder', 'The harness chooses')
  await writeNote(page)
  expect(runs()[0]).not.toContain('--model')
})

test('the default model of the settings is the one used, and is said, until another is chosen', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  const saved = page.getByRole('combobox', { name: 'Default model of Claude Code' })
  await saved.fill('sonnet')
  await saved.press('Enter')
  await expect(saved).toHaveValue('sonnet')

  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  // The default is what the box holds, as a choice that is already made.
  await expect(model(page)).toHaveValue('sonnet')
  await writeNote(page)
  expect(runs()[0]).toContain('--model sonnet')

  // Another for one note wins over it, and the default is as it was. The first note is taken away,
  // since a note that is written again is not a new one.
  rmSync(join(vault, 'research', 'Stub note.md'))
  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  await choose(page, 'haiku')
  await writeNote(page)
  expect(runs()[1]).toContain('--model haiku')
  expect(runs()[1]).not.toContain('sonnet')
})

test('a note is changed with the model chosen for the change', async ({ page }) => {
  await openNewNote(page)
  await writeNote(page)
  await page.getByRole('button', { name: 'Edit with an agent' }).click()
  await choose(page, 'haiku')
  await page.getByLabel('What should change?').fill('Add a line about the model')
  await page.getByRole('button', { name: 'Change the note' }).click()
  // The change is a second run, which is logged when it starts.
  await expect.poll(() => runs().length).toBe(2)
  expect(runs()[1]).toContain('--model haiku')
})

test('a definition is built with the model chosen, and the choice is left when the harness changes', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'New pipeline' }).click()
  await page.getByRole('button', { name: 'Build with an agent' }).click()
  await choose(page, 'opus')

  // Another harness has other models, so the choice is dropped.
  await harness(page).selectOption('Codex')
  await expect(model(page)).toHaveValue('')
  await harness(page).selectOption('Claude')

  await choose(page, 'opus')
  await page.getByLabel('Describe what it should do').fill('A pipeline for the model test')
  await page.getByRole('button', { name: 'Build', exact: true }).click()
  await expect.poll(() => runs().length).toBe(1)
  expect(runs()[0]).toContain('--model opus')
})

test('the harness of a run is the default one to begin with, and another can be chosen', async ({
  page,
}) => {
  await openNewNote(page)
  await expect(harness(page)).toHaveValue('Claude')
  await harness(page).selectOption('Codex')
  await choose(page, 'gpt-stub-a')
  await writeNote(page)
  expect(runs()).toHaveLength(1)
  expect(runs()[0]).toMatch(/^codex exec /)
  expect(runs()[0]).toContain('-m gpt-stub-a')
  expect(runs()[0]).not.toContain('--model')
})

test('the harness and the model begin as the settings have them, and follow the harness', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await page.getByRole('combobox', { name: 'Default harness' }).selectOption('Codex')
  const claude = page.getByRole('combobox', { name: 'Default model of Claude Code' })
  await claude.fill('sonnet')
  await claude.press('Enter')
  // Each default is kept before the next is set, as a person does it.
  await expect.poll(() => keptModels()).toEqual({ Claude: 'sonnet' })
  // The page has the saved default once the way back to the harness's own is offered.
  await expect(page.getByRole('button', { name: "Use the harness's own" })).toHaveCount(1)
  const codex = page.getByRole('combobox', { name: 'Default model of Codex' })
  await codex.fill('gpt-stub-b')
  await codex.press('Enter')
  await expect.poll(() => keptModels()).toEqual({ Claude: 'sonnet', Codex: 'gpt-stub-b' })

  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  await expect(harness(page)).toHaveValue('Codex')
  await expect(model(page)).toHaveValue('gpt-stub-b')
  await harness(page).selectOption('Claude')
  await expect(model(page)).toHaveValue('sonnet')
  await harness(page).selectOption('Opencode')
  await expect(model(page)).toHaveValue('')
  await expect(model(page)).toHaveAttribute('placeholder', 'The harness chooses')
})

test('a model chosen for a run can be given up for the default again', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  const saved = page.getByRole('combobox', { name: 'Default model of Claude Code' })
  await saved.fill('sonnet')
  await saved.press('Enter')
  await expect(saved).toHaveValue('sonnet')

  await openSection(page, 'Vault')
  await sidePanel(page).getByRole('button', { name: 'New note' }).click()
  await expect(page.getByRole('button', { name: 'Back to the default' })).toHaveCount(0)
  await choose(page, 'opus')
  await page.getByRole('button', { name: 'Back to the default' }).click()
  await expect(model(page)).toHaveValue('sonnet')
  await expect(page.getByRole('button', { name: 'Back to the default' })).toHaveCount(0)
  await writeNote(page)
  expect(runs()[0]).toContain('--model sonnet')
})

test('the model box is not wider than a model name needs', async ({ page }) => {
  await openNewNote(page)
  const box = await model(page).boundingBox()
  expect(box!.width).toBeLessThanOrEqual(330)
  expect(box!.width).toBeGreaterThanOrEqual(160)
})

test('the harness and the model are as high as each other, and each label is centred on its control', async ({
  page,
}) => {
  await openNewNote(page)
  const box = async (locator: ReturnType<Page['locator']>) => (await locator.boundingBox())!
  const select = await box(harness(page))
  const input = await box(model(page))
  expect(Math.abs(select.height - input.height)).toBeLessThanOrEqual(1)
  expect(Math.abs(select.y - input.y)).toBeLessThanOrEqual(1)
  for (const [label, control] of [
    ['Harness', select],
    ['Model', input],
  ] as const) {
    const text = await box(page.locator('.run-choice-part > span', { hasText: label }))
    const textCentre = text.y + text.height / 2
    const controlCentre = control.y + control.height / 2
    expect(Math.abs(textCentre - controlCentre), label).toBeLessThanOrEqual(1)
  }
})
