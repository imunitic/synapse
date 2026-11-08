import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

test.beforeEach(() => resetWorldSettings())
test.afterEach(() => resetWorldSettings())

async function openGeneral(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()
}

const picker = (page: Page, harness: 'Claude Code' | 'Codex' | 'OpenCode') =>
  page.getByRole('combobox', { name: `Default model of ${harness}` })

// What the app has kept, from its configuration file.
const kept = (): Record<string, string> =>
  (
    JSON.parse(readFileSync(join(world().xdg, 'synapse-desktop', 'config.json'), 'utf8')) as {
      defaultModels?: Record<string, string>
    }
  ).defaultModels ?? {}

test('has a model to choose for each harness, and none chosen to begin with', async ({ page }) => {
  await openGeneral(page)
  const card = page.getByRole('region', { name: 'Default models' })
  await expect(card).toBeVisible()
  for (const harness of ['Claude Code', 'Codex', 'OpenCode'] as const) {
    await expect(picker(page, harness)).toHaveValue('')
  }
  expect(kept()).toEqual({})
})

test('searches the models OpenCode lists, shows which can be used, and keeps the one chosen', async ({
  page,
}) => {
  await openGeneral(page)
  const box = picker(page, 'OpenCode')
  await box.click()
  const list = page.getByRole('listbox', { name: 'Models of Default model of OpenCode' })
  await expect(list.getByRole('option')).toHaveCount(4)
  // The models of connected providers, and OpenCode's own, come first; the rest are said to need a login.
  await expect(list.getByRole('option').nth(3)).toContainText('anthropic/claude-sonnet-5')
  await expect(list.getByRole('option').nth(3)).toContainText('not connected')
  await expect(list.getByRole('option').first()).not.toContainText('not connected')

  await box.fill('glm flash')
  await expect(list.getByRole('option')).toHaveCount(2)
  await list.getByRole('option', { name: /openrouter\/z-ai\/glm-5\.3-flash/ }).click()
  await expect(box).toHaveValue('openrouter/z-ai/glm-5.3-flash')
  await expect(list).toHaveCount(0)
  await expect.poll(kept).toEqual({ Opencode: 'openrouter/z-ai/glm-5.3-flash' })

  // It is there after the page is read again.
  await openGeneral(page)
  await expect(picker(page, 'OpenCode')).toHaveValue('openrouter/z-ai/glm-5.3-flash')
})

test('lists the aliases Claude Code takes, from its own /model, and takes a full name as well', async ({
  page,
}) => {
  await openGeneral(page)
  const box = picker(page, 'Claude Code')
  await box.click()
  const list = page.getByRole('listbox', { name: 'Models of Default model of Claude Code' })
  await expect(list.getByRole('option')).toHaveText(['sonnet', 'opus', 'haiku', 'default'])
  await expect(
    page.getByText('It is on Stub 1 now. Any full model ID can be typed as well.'),
  ).toBeVisible()
  await list.getByRole('option', { name: 'opus' }).click()
  await expect.poll(kept).toEqual({ Claude: 'opus' })

  // A name that is not an alias is used as it is.
  await box.fill('claude-full-id-1')
  await box.press('Enter')
  await expect.poll(kept).toEqual({ Claude: 'claude-full-id-1' })
})

test('lists the models Codex shows, in its order, each with what it says of it', async ({
  page,
}) => {
  await openGeneral(page)
  const box = picker(page, 'Codex')
  await box.click()
  const options = page
    .getByRole('listbox', { name: 'Models of Default model of Codex' })
    .getByRole('option')
  // The hidden one is not offered, and the priority is the order.
  await expect(options).toHaveCount(2)
  await expect(options.nth(0)).toContainText('gpt-stub-a')
  await expect(options.nth(0)).toContainText('Stub A: The first.')
  await expect(options.nth(1)).toContainText('gpt-stub-b')
  await options.nth(1).click()
  await expect.poll(kept).toEqual({ Codex: 'gpt-stub-b' })
})

test('refuses a name that could be taken for a flag, and keeps what was chosen', async ({
  page,
}) => {
  await openGeneral(page)
  const box = picker(page, 'Codex')
  await box.fill('gpt-x')
  await box.press('Enter')
  await expect.poll(kept).toEqual({ Codex: 'gpt-x' })

  await box.fill('--dangerously-skip-permissions')
  await box.press('Enter')
  await expect(
    page.getByRole('alert').filter({ hasText: 'A model name has letters' }),
  ).toBeVisible()
  expect(kept()).toEqual({ Codex: 'gpt-x' })
  // Leaving it puts back what was chosen.
  await box.press('Escape')
  await expect(box).toHaveValue('gpt-x')
  await expect(page.getByRole('alert').filter({ hasText: 'A model name has letters' })).toHaveCount(
    0,
  )
})

test('goes back to the harness own model when it is cleared', async ({ page }) => {
  await openGeneral(page)
  const box = picker(page, 'Codex')
  await box.fill('gpt-x')
  await box.press('Enter')
  await expect.poll(kept).toEqual({ Codex: 'gpt-x' })
  await page.getByRole('button', { name: "Use the harness's own" }).click()
  await expect(box).toHaveValue('')
  await expect.poll(kept).toEqual({})
  await expect(page.getByRole('button', { name: "Use the harness's own" })).toHaveCount(0)
})

test('is used from the keyboard: arrows to a model, Enter to take it, Escape to leave', async ({
  page,
}) => {
  await openGeneral(page)
  const box = picker(page, 'OpenCode')
  await box.click()
  // The list is read when the box is first used, and arrows have nothing to move through before.
  await expect(page.getByRole('listbox').getByRole('option')).toHaveCount(4)
  await box.press('ArrowDown')
  await box.press('ArrowDown')
  await expect(page.getByRole('listbox').getByRole('option').nth(2)).toHaveAttribute(
    'aria-selected',
    'true',
  )
  await box.press('Enter')
  await expect(box).toHaveValue('openrouter/z-ai/glm-5.3-flash')
  await expect.poll(kept).toEqual({ Opencode: 'openrouter/z-ai/glm-5.3-flash' })

  await box.fill('deepseek')
  await box.press('Escape')
  await expect(box).toHaveValue('openrouter/z-ai/glm-5.3-flash')
})

test('says that a typed name that is not listed is used as it is', async ({ page }) => {
  await openGeneral(page)
  const box = picker(page, 'OpenCode')
  await box.fill('nothing/matches-this')
  await expect(page.getByText('No listed model has those words.')).toBeVisible()
  await box.press('Enter')
  await expect.poll(kept).toEqual({ Opencode: 'nothing/matches-this' })
})

// The programs the app ran to read the lists of models, a line for each.
const reads = (): string[] => {
  const log = join(world().root, 'model-reads.log')
  return existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : []
}

test.describe('the lists of models are kept', () => {
  test('and read for the three harnesses when the app starts, into a file', async ({ page }) => {
    await page.goto('/')
    // The app began before the page did, and has read each list.
    await expect
      .poll(() =>
        reads()
          .map((r) => r.split(' ')[0])
          .sort(),
      )
      .toEqual(expect.arrayContaining(['claude', 'codex', 'opencode']))
    const file = join(world().home, '.cache', 'synapse-desktop', 'models.json')
    await expect.poll(() => existsSync(file)).toBe(true)
    const kept = JSON.parse(readFileSync(file, 'utf8')) as {
      harnesses: Record<string, { models: { id: string }[] }>
    }
    expect(Object.keys(kept.harnesses).sort()).toEqual(['Claude', 'Codex', 'Opencode'])
    expect(kept.harnesses.Claude?.models.map((m) => m.id)).toContain('sonnet')
    expect(kept.harnesses.Codex?.models.map((m) => m.id)).toContain('gpt-stub-a')
  })

  test('so that a picker is answered from what is kept, and no program is run for it', async ({
    page,
  }) => {
    const before = reads().length
    await openGeneral(page)
    const box = picker(page, 'OpenCode')
    await box.click()
    await expect(page.getByRole('listbox').getByRole('option')).toHaveCount(4)
    await picker(page, 'Claude Code').click()
    await expect(page.getByRole('listbox').getByRole('option')).toHaveCount(4)
    expect(reads().slice(before)).toEqual([])
  })

  test('and say when they were read, and are read again from the harness when asked to', async ({
    page,
  }) => {
    await openGeneral(page)
    const box = picker(page, 'OpenCode')
    await box.click()
    await expect(page.getByText(/^Read .+\./)).toBeVisible()
    const before = reads().length

    await page.getByRole('button', { name: 'Read again' }).click()
    // Only OpenCode was read, with its models and its providers.
    await expect
      .poll(() => reads().slice(before).sort())
      .toEqual(['opencode auth list', 'opencode models'])
    await expect(page.getByRole('button', { name: 'Read again' })).toBeEnabled()
    // The list is still there, and the box kept the focus, so that it stayed open.
    await expect(page.getByRole('listbox').getByRole('option')).toHaveCount(4)
  })
})
