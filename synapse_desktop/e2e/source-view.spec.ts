import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Locator, type Page } from './fixtures.ts'
import { openSection, sidePanel, startRunWithoutTerminal, uniqueName, world } from './helpers.ts'

// A prompt definition of the given name, as its file holds it: short enough that every line of it
// is in view, which is all the editor renders.
const promptText = (name: string) =>
  `-- Counts to three.
Prompt ${name} [
   Description => "Counts.",
   Prompt => "One, two, three."
];
`

// Writes a prompt of its own into the world, holding the text made for its name, hands it to
// `use`, then removes it.
async function withDefinition(
  text: (name: string) => string,
  use: (made: { name: string; path: string }) => Promise<void>,
) {
  const name = uniqueName('Source')
  const path = join(world().definitions, `${name}.synapse`)
  writeFileSync(path, text(name))
  try {
    await use({ name, path })
  } finally {
    rmSync(path, { force: true })
  }
}

// Opens the app on a list of definitions, where the one of the given name is.
async function listDefinitions(
  page: Page,
  kind: 'Pipelines' | 'Systems' | 'Prompts',
  name: string,
) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: kind, exact: true }).click()
  const item = sidePanel(page).getByRole('button', { name: new RegExp(`^${name}( |$)`) })
  await expect(item).toBeVisible()
  return item
}

const sourceCard = (page: Page) => page.getByRole('region', { name: 'Source', exact: true })

// Opens the page of the prompt of the given name.
async function openSource(page: Page, name: string) {
  await (await listDefinitions(page, 'Prompts', name)).click()
  const card = sourceCard(page)
  const text = card.getByRole('textbox', { name: 'Source text' })
  await expect(text).toBeVisible()
  return { card, text, lines: card.locator('.cm-line') }
}

// The lines the editor shows, as one text.
async function shown(page: Page): Promise<string> {
  return (await sourceCard(page).locator('.cm-line').allTextContents()).join('\n')
}

const clipboard = (page: Page) => page.evaluate(() => navigator.clipboard.readText())

const colorOf = (element: Element) => getComputedStyle(element).color

test('the source card shows the title, the path and the file with numbered lines', async ({
  page,
}) => {
  await withDefinition(promptText, async ({ name, path }) => {
    const { card } = await openSource(page, name)
    await expect(card.getByRole('heading', { name: 'Source' })).toBeVisible()
    await expect(card.getByText(path, { exact: true })).toBeVisible()
    await expect.poll(() => shown(page)).toBe(promptText(name))
    // The first number element of a gutter is a hidden one that sizes it.
    const numbers = card.locator('.cm-lineNumbers .cm-gutterElement:visible')
    await expect(numbers).toHaveText(['1', '2', '3', '4', '5', '6'])
    await expect(card.locator('pre')).toHaveCount(0)
  })
})

test('the source is highlighted as the definition language', async ({ page }) => {
  await withDefinition(promptText, async ({ name }) => {
    const { text, lines } = await openSource(page, name)
    const keyword = lines.nth(1).getByText('Prompt', { exact: true })
    await expect(keyword).toBeVisible()
    // Plain text has the color of the content, which the brackets keep.
    expect(await keyword.evaluate(colorOf)).not.toBe(await text.evaluate(colorOf))
  })
})

test('the source text cannot be changed by typing, deleting, pasting or cutting', async ({
  page,
  context,
}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await withDefinition(promptText, async ({ name, path }) => {
    const { text, lines } = await openSource(page, name)
    await expect(text).toHaveAttribute('aria-readonly', 'true')
    const unchanged = async () => {
      await expect.poll(() => shown(page)).toBe(promptText(name))
      expect(readFileSync(path, 'utf8')).toBe(promptText(name))
    }

    await lines.nth(2).click()
    await expect(text).toBeFocused()
    await page.keyboard.type('typed')
    await unchanged()
    for (const key of ['Enter', 'Backspace', 'Delete', 'ControlOrMeta+Backspace']) {
      await page.keyboard.press(key)
      await unchanged()
    }

    await page.evaluate(() => navigator.clipboard.writeText('pasted'))
    await page.keyboard.press('ControlOrMeta+V')
    await unchanged()

    await page.keyboard.press('ControlOrMeta+A')
    await page.keyboard.press('ControlOrMeta+X')
    // Cutting copies, so it has run once the clipboard holds the file.
    await expect.poll(() => clipboard(page)).toBe(promptText(name))
    await unchanged()
  })
})

test('selecting all of the source and copying it gives the whole file', async ({
  page,
  context,
}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await withDefinition(promptText, async ({ name }) => {
    const { lines } = await openSource(page, name)
    await lines.first().click()
    await page.keyboard.press('ControlOrMeta+A')
    await page.keyboard.press('ControlOrMeta+C')
    await expect.poll(() => clipboard(page)).toBe(promptText(name))
  })
})

test('the arrow keys move the cursor in the source, and Shift extends the selection', async ({
  page,
  context,
}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await withDefinition(promptText, async ({ name }) => {
    const { lines } = await openSource(page, name)
    const press = async (key: string, times = 1) => {
      for (let i = 0; i < times; i++) await page.keyboard.press(key)
    }
    const copied = async (expected: string) => {
      await press('ControlOrMeta+C')
      await expect.poll(() => clipboard(page)).toBe(expected)
    }

    await lines.first().click()
    await press('Home')
    await press('ArrowRight', 3)
    await press('Shift+ArrowRight', 6)
    await copied('Counts')

    await press('Home')
    await press('ArrowDown', 2)
    await press('ArrowRight', 3)
    await press('Shift+ArrowRight', 11)
    await copied('Description')

    // Left puts the cursor at the start of the selection, and Up takes it a line higher.
    await press('ArrowLeft')
    await press('ArrowUp')
    await press('Shift+ArrowRight', 3)
    await copied('mpt')

    await press('ArrowRight')
    await press('Shift+ArrowLeft', 6)
    await copied('Prompt')
  })
})

test('a file removed after it was listed says that it could not be read', async ({ page }) => {
  await withDefinition(promptText, async ({ name, path }) => {
    const item = await listDefinitions(page, 'Prompts', name)
    rmSync(path)
    await item.click()
    const card = sourceCard(page)
    await expect(card.getByRole('alert')).toContainText('Could not read the file')
    await expect(card.getByRole('textbox')).toHaveCount(0)
  })
})

test('the source view has no lint gutter or active line, and Tab leaves it', async ({ page }) => {
  await withDefinition(promptText, async ({ name }) => {
    const { card, text, lines } = await openSource(page, name)
    await lines.nth(2).click()
    await expect(text).toBeFocused()
    await expect(card.locator('.cm-gutter-lint')).toHaveCount(0)
    await expect(card.locator('.cm-activeLine')).toHaveCount(0)
    await page.keyboard.press('Tab')
    await expect(text).not.toBeFocused()
  })
})

test('the definition editor keeps its lint gutter, active line, Tab indent and undo', async ({
  page,
}) => {
  await withDefinition(promptText, async ({ name }) => {
    await openSource(page, name)
    await page.getByRole('button', { name: 'Edit', exact: true }).click()
    const card = page.getByRole('region', { name: 'Editor', exact: true })
    const text = card.getByRole('textbox')
    const first = card.locator('.cm-line').first()
    await first.click()
    await expect(card.locator('.cm-gutter-lint')).toBeVisible()
    await expect(card.locator('.cm-activeLine')).toBeVisible()

    await page.keyboard.press('Home')
    await page.keyboard.press('Tab')
    await expect(first).toHaveText('  -- Counts to three.', { useInnerText: true })
    await expect(text).toBeFocused()

    await page.keyboard.press('End')
    await page.keyboard.type(' More.')
    await expect(first).toContainText('More.')
    await page.keyboard.press('ControlOrMeta+Z')
    await expect(first).not.toContainText('More.')
  })
})

// A prompt definition with the given lines of comment after it.
const withComments = (name: string, comments: readonly string[]) =>
  promptText(name) + comments.map((comment) => `-- ${comment}\n`).join('')

// How much room a scrolling element has, and how much its content takes.
const sizes = (element: Element) => ({
  width: element.clientWidth,
  scrollWidth: element.scrollWidth,
  height: element.clientHeight,
  scrollHeight: element.scrollHeight,
})

// The editor in the card scrolls sideways, and neither the card nor anything around it does.
async function expectScrollsInside(page: Page, card: Locator) {
  const scroller = await card.locator('.cm-scroller').evaluate(sizes)
  expect(scroller.scrollWidth).toBeGreaterThan(scroller.width)
  for (const outer of [card, page.locator('.content'), page.locator('html')]) {
    const { width, scrollWidth } = await outer.evaluate(sizes)
    expect(scrollWidth).toBeLessThanOrEqual(width)
  }
  const cardBox = await card.boundingBox()
  const editorBox = await card.locator('.cm-editor').boundingBox()
  expect(editorBox!.x + editorBox!.width).toBeLessThanOrEqual(cardBox!.x + cardBox!.width)
}

test('a long line stays one line and scrolls inside the editor', async ({ page }) => {
  const long = (name: string) => withComments(name, ['word '.repeat(400)])
  await withDefinition(long, async ({ name }) => {
    const { card, lines } = await openSource(page, name)
    const longLine = lines.filter({ hasText: 'word word' })
    await expect(longLine).toBeVisible()
    const heightOf = async (line: Locator) => (await line.boundingBox())?.height
    expect(await heightOf(longLine)).toBe(await heightOf(lines.first()))
    await expectScrollsInside(page, card)
  })
})

test('the source view of a short file is as tall as the file', async ({ page }) => {
  const short = (name: string) => `Prompt ${name} [
   Description => "Counts.", Prompt => "One."
];`
  await withDefinition(short, async ({ name }) => {
    const { card, lines } = await openSource(page, name)
    await expect(lines).toHaveCount(3)
    expect((await card.locator('.cm-editor').boundingBox())!.height).toBeLessThan(220)
    const scroller = await card.locator('.cm-scroller').evaluate(sizes)
    expect(scroller.scrollHeight).toBeLessThanOrEqual(scroller.height)
  })
})

test('the source view of a long file takes most of the window and scrolls', async ({ page }) => {
  const long = (name: string) =>
    withComments(
      name,
      Array.from({ length: 400 }, (_, i) => `line ${i + 1}`),
    )
  await withDefinition(long, async ({ name }) => {
    const { card, lines } = await openSource(page, name)
    const scroller = card.locator('.cm-scroller')
    const window = await page.evaluate(() => innerHeight)
    const { height, scrollHeight } = await scroller.evaluate(sizes)
    expect(Math.abs(height - window * 0.7)).toBeLessThanOrEqual(1)
    expect(scrollHeight).toBeGreaterThan(height)

    const last = lines.getByText('-- line 400', { exact: true })
    await expect(last).toHaveCount(0)
    // The height of lines not yet drawn is a guess, so the end may move while scrolling to it.
    await expect(async () => {
      await scroller.evaluate((element) => element.scrollTo(0, element.scrollHeight))
      await expect(last).toBeVisible({ timeout: 500 })
    }).toPass()
  })
})

test('the definition editor keeps its own limits of height', async ({ page }) => {
  await withDefinition(promptText, async ({ name }) => {
    await openSource(page, name)
    await page.getByRole('button', { name: 'Edit', exact: true }).click()
    const scroller = page
      .getByRole('region', { name: 'Editor', exact: true })
      .locator('.cm-scroller')
    await expect(scroller).toHaveCSS('min-height', '220px')
    await expect(scroller).toHaveCSS('max-height', '460px')
  })
})

// A window narrow enough that a line of the world's definitions is wider than the Source card.
const NARROW = { width: 760, height: 800 }

// The text of one of the world's definition files.
const definitionText = (file: string) => readFileSync(join(world().definitions, file), 'utf8')

// The Source card shows the file highlighted and read-only, and in a narrow window its editor
// scrolls a wide line while the page does not.
async function expectReadOnlySource(page: Page, file: string, keyword: string) {
  const card = sourceCard(page)
  const text = card.getByRole('textbox', { name: 'Source text' })
  await expect(text).toHaveAttribute('aria-readonly', 'true')
  await expect.poll(() => shown(page)).toBe(definitionText(file))
  const word = card.locator('.cm-line').getByText(keyword, { exact: true }).first()
  expect(await word.evaluate(colorOf)).not.toBe(await text.evaluate(colorOf))
  await page.setViewportSize(NARROW)
  await expectScrollsInside(page, card)
}

test('a system page shows its source read-only, scrolling a wide line inside it', async ({
  page,
}) => {
  await (await listDefinitions(page, 'Systems', 'Strict_Reviewer')).click()
  await expectReadOnlySource(page, 'Strict_Reviewer.synapse', 'System')
})

test('a pipeline page shows its source read-only, scrolling a wide line inside it', async ({
  page,
}) => {
  await (await listDefinitions(page, 'Pipelines', 'Develop_Feature')).click()
  await expectReadOnlySource(page, 'Develop_Feature.synapse', 'Pipeline')
})

// Opens the page of a run, and gives its card of recorded definitions.
async function openRecorded(page: Page, id: string) {
  await page.goto('/')
  await openSection(page, 'Executions')
  await sidePanel(page).locator(`.list-row[data-execution="${id}"] .list-item`).click()
  await expect(page.getByRole('heading', { level: 1, name: id })).toBeVisible()
  return page.getByRole('region', { name: 'Definitions it ran', exact: true })
}

test('a recorded definition of a run is shown read-only, scrolling a wide line inside it', async ({
  page,
}) => {
  const recorded = await openRecorded(page, 'exec-fixture1')
  await recorded.getByRole('button', { name: 'pipeline Fixture_Run', exact: true }).click()
  await expectReadOnlySource(page, 'Fixture_Run.synapse', 'Pipeline')
})

test('choosing another recorded definition shows the text of that file', async ({ page }) => {
  const id = await startRunWithoutTerminal(page, 'Develop_Feature')
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({ timeout: 30_000 })
  // The page reads the recorded files once, when it appears.
  const recorded = await openRecorded(page, id)
  const card = sourceCard(page)
  const files = [
    ['pipeline Develop_Feature', 'Develop_Feature.synapse'],
    ['agent Developer', 'Developer.synapse'],
    ['pipeline Develop_Feature', 'Develop_Feature.synapse'],
  ] as const
  for (const [label, file] of files) {
    await recorded.getByRole('button', { name: label, exact: true }).click()
    await expect(card.locator('p.mono')).toContainText(file)
    await expect.poll(() => shown(page)).toBe(definitionText(file))
    await expect(card.locator('.cm-editor')).toHaveCount(1)
    await expect(card.getByRole('textbox')).toHaveAttribute('aria-readonly', 'true')
  }
})
