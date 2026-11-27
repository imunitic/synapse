import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { overrideBus } from './bus.ts'
import { expect, test, type Page } from './fixtures.ts'
import { openSection, sidePanel, world } from './helpers.ts'

const panelTitle = (page: Page, name: string) =>
  sidePanel(page).getByRole('heading', { level: 2, name })

// The call that lists the definitions, answered with none of them.
async function withNoDefinitions(page: Page) {
  await overrideBus(page, {
    cli: (real, params) => {
      const { args } = params as { args: string[] }
      const result = real as { stdout: string }
      if (!args.includes('definitions')) return { result }
      const listing = JSON.parse(result.stdout) as { definitions: unknown[] }
      listing.definitions = []
      return { result: { ...result, stdout: JSON.stringify(listing) } }
    },
  })
}

// A call that is still being answered when a test ends is left to end, and is not an error.
test.afterEach(async ({ page }) => {
  await page.unrouteAll({ behavior: 'ignoreErrors' })
})

test.describe('the side panel follows the page', () => {
  test('is on the executions for a run, and on its own kind for a definition', async ({ page }) => {
    await page.goto('/')
    await openSection(page, 'Executions')
    await sidePanel(page).locator('.list-item').first().click()
    const run = await page.locator('.tabbar .tab[data-selected="true"] [role="tab"]').innerText()

    await openSection(page, 'Definitions')
    await sidePanel(page).getByRole('button', { name: 'Agents', exact: true }).click()
    await sidePanel(page).getByRole('button', { name: 'Developer' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Developer' })).toBeVisible()

    // The Home page belongs to no section, so the panel is where it was.
    await sidePanel(page).getByRole('button', { name: 'Pipelines', exact: true }).click()
    await page.getByRole('tab', { name: 'Home', exact: true }).click()
    await expect(sidePanel(page).getByRole('button', { name: 'Pipelines' })).toHaveAttribute(
      'aria-pressed',
      'true',
    )

    // A run, and then a definition: the panel goes to each page's own place.
    await page.getByRole('tab', { name: run, exact: true }).click()
    await expect(panelTitle(page, 'Executions')).toBeVisible()
    await page.getByRole('tab', { name: 'Developer', exact: true }).click()
    await expect(panelTitle(page, 'Definitions')).toBeVisible()
    await expect(sidePanel(page).getByRole('button', { name: 'Agents' })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
  })

  test('does not open a panel that was shut, and then has the right section when it is opened', async ({
    page,
  }) => {
    await page.goto('/')
    await openSection(page, 'Executions')
    await sidePanel(page).locator('.list-item').first().click()
    const run = await page.locator('.tabbar .tab[data-selected="true"] [role="tab"]').innerText()
    await openSection(page, 'Definitions')
    await page.getByRole('button', { name: 'Show or hide the side panel' }).click()
    await expect(sidePanel(page)).toHaveCount(0)

    // Home is a page of no section, and the run is the page that comes to show.
    await page.getByRole('tab', { name: 'Home', exact: true }).click()
    await page.getByRole('tab', { name: run, exact: true }).click()
    await expect(sidePanel(page)).toHaveCount(0)
    await page.getByRole('button', { name: 'Show or hide the side panel' }).click()
    await expect(panelTitle(page, 'Executions')).toBeVisible()
  })

  test('lets the person choose another section for the page that is showing', async ({ page }) => {
    await page.goto('/')
    await openSection(page, 'Executions')
    await sidePanel(page).locator('.list-item').first().click()
    await openSection(page, 'Settings')
    await expect(panelTitle(page, 'Settings')).toBeVisible()
  })
})

test('a definition with a description shows it next to its name, and one without shows none', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Prompts', exact: true }).click()
  const described = sidePanel(page).locator('.list-entry', { hasText: 'Test_Feature' })
  await expect(described).toContainText('Run the tests for a feature and report which ones fail.')
  const plain = sidePanel(page).locator('.list-entry', { hasText: 'Review_Code' })
  await expect(plain.locator('.list-name-one-line')).toHaveCount(0)
})

test.describe('a list with nothing in it', () => {
  test('of definitions says so and leaves making one to the + that is there', async ({ page }) => {
    await withNoDefinitions(page)
    await page.goto('/')
    await openSection(page, 'Definitions')
    await sidePanel(page).getByRole('button', { name: 'Systems', exact: true }).click()
    await expect(sidePanel(page).getByText('No systems found.')).toBeVisible()
    // One way to make one, in the header, and no second button beside the message.
    await expect(sidePanel(page).getByRole('button', { name: 'New system' })).toHaveCount(1)
    await expect(sidePanel(page).locator('.panel-action')).toHaveCount(0)
    await sidePanel(page).getByRole('button', { name: 'New system' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'New system' })).toBeVisible()
  })

  test('of executions says where a run starts and goes to the pipelines', async ({ page }) => {
    await overrideBus(page, {
      'config.get': (real) => {
        const result = real as { paths: object }
        return { result: { ...result, paths: { ...result.paths, recordsDir: null } } }
      },
    })
    await page.goto('/')
    await openSection(page, 'Executions')
    await expect(sidePanel(page).getByText(/No executions found\./)).toContainText(
      "A run starts from a pipeline's page.",
    )
    await sidePanel(page).getByRole('button', { name: 'Open the pipelines' }).click()
    await expect(panelTitle(page, 'Definitions')).toBeVisible()
    await expect(sidePanel(page).getByRole('button', { name: 'Pipelines' })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
  })

  test('has no offer when the list is not empty', async ({ page }) => {
    await page.goto('/')
    await openSection(page, 'Definitions')
    await expect(sidePanel(page).locator('.list-item').first()).toBeVisible()
    await expect(sidePanel(page).getByRole('button', { name: /^New pipeline$/ })).toHaveCount(1)
    await expect(sidePanel(page).locator('.panel-action')).toHaveCount(0)
  })
})

test.describe('the label of a run in the Executions list', () => {
  const runs = [
    { id: 'exec-label-a', interactive: true as boolean | undefined },
    { id: 'exec-label-b', interactive: false as boolean | undefined },
    { id: 'exec-label-c', interactive: undefined as boolean | undefined },
  ]

  test('says interactive or autonomous, and nothing for a record without the field', async ({
    page,
  }) => {
    const dirs = runs.map((run) => join(world().work, 'pipelines', run.id))
    runs.forEach((run) => {
      const dir = join(world().work, 'pipelines', run.id)
      mkdirSync(dir, { recursive: true })
      writeFileSync(
        join(dir, 'execution.json'),
        JSON.stringify({
          format: 'synapse-pipeline-execution/v1',
          id: run.id,
          pipeline: 'Label_Run',
          started: new Date().toISOString(),
          ended: new Date().toISOString(),
          status: 'completed',
          current_step: null,
          state: { steps_run: 1 },
          ...(run.interactive === undefined ? {} : { interactive: run.interactive }),
        }),
      )
    })
    try {
      await page.goto('/')
      await openSection(page, 'Executions')
      const row = (id: string) => sidePanel(page).locator(`.list-row[data-execution="${id}"]`)
      await expect(row('exec-label-a')).toContainText('interactive')
      await expect(row('exec-label-b')).toContainText('autonomous')
      await expect(row('exec-label-c')).toBeVisible()
      await expect(row('exec-label-c')).not.toContainText('interactive')
      await expect(row('exec-label-c')).not.toContainText('autonomous')
    } finally {
      dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true }))
    }
  })
})
