import { expect, test, type Page } from '@playwright/test'
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
  expect(panel!.width).toBeGreaterThanOrEqual(260)
  expect(panel!.width).toBeLessThanOrEqual(310)
})

test('the texts name what is there: the Terminals page, not a panel that is gone', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'Terminals' }).click()
  await expect(page.getByText('unless you type another folder on the Terminals page')).toBeVisible()
  await expect(page.getByText('in the side panel')).toHaveCount(0)

  await page.getByRole('button', { name: 'Close Home' }).click()
  await page.getByRole('button', { name: 'Close Terminals settings' }).click()
  await expect(page.getByText('Open a page from the rail or the side panel.')).toBeVisible()
})
