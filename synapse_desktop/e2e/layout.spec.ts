import { expect, test, type Page } from './fixtures.ts'
import { openSection, sidePanel } from './helpers.ts'

const bar = (page: Page) => page.getByRole('tablist', { name: 'Open pages' })

// Settings pages, a tab each, and the two pages above the rail's divider: more tabs than a
// window of this width has room for.
async function openManyTabs(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  for (const item of await page.locator('.settings-item').all()) await item.click()
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await page.getByRole('button', { name: 'Terminals', exact: true }).click()
}

test.describe('more tabs than fit', () => {
  test('scroll, and the tab that is showing is in view', async ({ page }) => {
    await openManyTabs(page)
    const bounds = await bar(page).evaluate((el) => ({
      scroll: el.scrollWidth,
      shown: el.clientWidth,
    }))
    expect(bounds.scroll).toBeGreaterThan(bounds.shown)

    const barBox = await bar(page).boundingBox()
    const active = await page.locator('.tabbar .tab[data-selected="true"]').boundingBox()
    expect(active!.x).toBeGreaterThanOrEqual(barBox!.x - 1)
    expect(active!.x + active!.width).toBeLessThanOrEqual(barBox!.x + barBox!.width + 1)
  })

  test('are reached with the wheel, and a tab that is far off is opened and shown', async ({
    page,
  }) => {
    await openManyTabs(page)
    await bar(page).hover()
    await page.mouse.wheel(0, -5000)
    await expect.poll(() => bar(page).evaluate((el) => el.scrollLeft)).toBe(0)
    await page.getByRole('tab', { name: 'Home', exact: true }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
    // Back to the last one: it is brought into view.
    await page.getByRole('button', { name: 'Terminals', exact: true }).click()
    await expect
      .poll(async () => {
        const barBox = await bar(page).boundingBox()
        const box = await page.locator('.tabbar .tab[data-selected="true"]').boundingBox()
        return box!.x + box!.width <= barBox!.x + barBox!.width + 1
      })
      .toBe(true)
  })

  test('keep a width to read, and say their whole name when it is cut', async ({ page }) => {
    await openManyTabs(page)
    for (const tab of await page.locator('.tabbar .tab').all()) {
      expect((await tab.boundingBox())!.width).toBeGreaterThan(100)
    }
    await expect(page.getByRole('tab', { name: 'Conventions settings' })).toHaveAttribute(
      'title',
      'Conventions settings',
    )
  })
})

test.describe('a window that is narrow', () => {
  test.use({ viewport: { width: 900, height: 700 } })

  test('has the side panel shut, and nothing of the page is cut off', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
    await expect(sidePanel(page)).toHaveCount(0)
    const scrolls = await page.evaluate('document.documentElement.scrollWidth > window.innerWidth')
    expect(scrolls).toBe(false)
    // The panel can be opened by hand.
    await page.getByRole('button', { name: 'Show or hide the side panel' }).click()
    await expect(sidePanel(page)).toBeVisible()
  })
})

test('the side panel is a width that leaves the page room', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  const panel = await sidePanel(page).boundingBox()
  expect(panel!.width).toBeGreaterThanOrEqual(290)
  expect(panel!.width).toBeLessThanOrEqual(330)
})

test('the side panel is widened by dragging its handle, and keeps the width after a reload', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  const before = (await sidePanel(page).boundingBox())!.width
  const handle = (await page
    .getByRole('separator', { name: 'Resize the side panel' })
    .boundingBox())!
  const x = handle.x + handle.width / 2
  const y = handle.y + handle.height / 2
  await page.mouse.move(x, y)
  await page.mouse.down()
  await page.mouse.move(x + 60, y)
  await page.mouse.move(x + 120, y)
  await page.mouse.up()
  const after = (await sidePanel(page).boundingBox())!.width
  expect(Math.abs(after - before - 120)).toBeLessThanOrEqual(2)

  // One width serves every section.
  await openSection(page, 'Executions')
  expect((await sidePanel(page).boundingBox())!.width).toBeCloseTo(after, 0)

  await page.reload()
  await openSection(page, 'Definitions')
  expect((await sidePanel(page).boundingBox())!.width).toBeCloseTo(after, 0)
})

test("the side panel's handle moves with the arrow keys and stops at its limits", async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  const handle = page.getByRole('separator', { name: 'Resize the side panel' })
  const width = async () => (await sidePanel(page).boundingBox())!.width
  await handle.focus()
  const start = await width()

  await page.keyboard.press('ArrowRight')
  expect(await width()).toBeCloseTo(start + 16, 0)
  await page.keyboard.press('Shift+ArrowRight')
  expect(await width()).toBeCloseTo(start + 80, 0)

  for (let i = 0; i < 20; i++) await page.keyboard.press('ArrowLeft')
  const min = Number(await handle.getAttribute('aria-valuemin'))
  const rem = (await page.evaluate(
    'parseFloat(getComputedStyle(document.documentElement).fontSize)',
  )) as number
  expect(min).toBeCloseTo(16.5 * rem, 5)
  expect(await width()).toBeCloseTo(min, 0)
  await expect(handle).toHaveAttribute('aria-valuenow', String(Math.round(min)))
})

test('the texts name what is there: the Terminals page, not a panel that is gone', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'Terminals' }).click()
  await expect(page.getByText('unless you type another folder on the Terminals page')).toBeVisible()
  await expect(page.getByText('in the side panel')).toHaveCount(0)
})

test('every button of the rail says what it is when the pointer rests on it', async ({ page }) => {
  await page.goto('/')
  const buttons = await page.getByRole('navigation', { name: 'Sections' }).getByRole('button').all()
  expect(buttons).toHaveLength(8)
  for (const button of buttons) {
    const name = await button.getAttribute('aria-label')
    expect(name).not.toBeNull()
    await expect(button).toHaveAttribute('title', name!)
  }
})

test('a form puts its label above its input, on the Terminals page and in the settings', async ({
  page,
}) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Terminals', exact: true }).click()
  for (const label of ['Start in', 'Another folder']) {
    const field = page.getByLabel(label).first()
    const text = page.locator('label.field', { has: field }).locator('span').first()
    const above = await text.boundingBox()
    const input = await field.boundingBox()
    expect(above!.y + above!.height).toBeLessThanOrEqual(input!.y + 1)
  }
})

test('the page of the vault does not call its first card by its own name', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'Vault' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Vault' })).toBeVisible()
  await expect(page.getByRole('heading', { level: 2, name: 'Vault folder' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Vault', exact: true })).toHaveCount(1)
})

test('the kinds of definition stay in one row in the side panel', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  const tops = await sidePanel(page)
    .getByRole('group', { name: 'Kind of definition' })
    .getByRole('button')
    .evaluateAll((buttons) => buttons.map((b) => Math.round(b.getBoundingClientRect().top)))
  expect(tops).toHaveLength(4)
  expect(new Set(tops).size).toBe(1)
})

test('a select has an arrow of its own held away from the border, as every select does', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()
  const style = (nth: number, property: string) =>
    page.evaluate(`getComputedStyle(document.querySelectorAll('.page select')[${nth}]).${property}`)
  const count = (await page.evaluate("document.querySelectorAll('.page select').length")) as number
  expect(count).toBeGreaterThanOrEqual(2)
  for (let i = 0; i < count; i++) {
    expect(await style(i, 'appearance'), `select ${i}`).toBe('none')
    expect(await style(i, 'backgroundImage'), `select ${i}`).toContain('svg')
    // Room for the arrow, which is 12 px from the right edge.
    expect(
      parseFloat((await style(i, 'paddingRight')) as string),
      `select ${i}`,
    ).toBeGreaterThanOrEqual(30)
    expect(await style(i, 'backgroundPositionX'), `select ${i}`).toContain('calc(100% - 12px)')
  }
})
