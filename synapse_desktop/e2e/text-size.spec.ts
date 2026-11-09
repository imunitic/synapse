import { expect, test, type Page } from '@playwright/test'
import { launchCard, openLaunch, openSection, resetWorldSettings, sidePanel } from './helpers.ts'

test.beforeEach(() => resetWorldSettings())
test.afterEach(() => resetWorldSettings())

// The browser's own functions are named in strings, since the tests are not typed for a page.
const rootSize = (page: Page): Promise<string> =>
  page.evaluate('getComputedStyle(document.documentElement).fontSize')
const bodySize = (page: Page): Promise<string> =>
  page.evaluate('getComputedStyle(document.body).fontSize')

async function openGeneral(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()
}

test('the text is a little bigger than the browser size by default', async ({ page }) => {
  await page.goto('/')
  expect(await rootSize(page)).toBe('18px')
  // A size in the stylesheet follows the root: the body is 14px at the browser size.
  expect(await bodySize(page)).toBe('15.75px')
})

test('the Text size setting scales the whole app at once and is kept after a reload', async ({
  page,
}) => {
  await openGeneral(page)
  const choice = page.getByRole('combobox', { name: 'Text size' })
  await expect(choice.locator('option')).toHaveText([
    'Small (100%)',
    'Default (112.5%)',
    'Large (125%)',
    'Larger (150%)',
  ])
  await expect(choice).toHaveValue('112.5')

  await choice.selectOption('125')
  expect(await rootSize(page)).toBe('20px')
  expect(await bodySize(page)).toBe('17.5px')

  await page.reload()
  expect(await rootSize(page)).toBe('20px')
  await openGeneral(page)
  await expect(page.getByRole('combobox', { name: 'Text size' })).toHaveValue('125')

  await page.getByRole('combobox', { name: 'Text size' }).selectOption('100')
  expect(await rootSize(page)).toBe('16px')
})

test('a size that is not on offer is the default', async ({ page }) => {
  await page.goto('/')
  await page.evaluate("localStorage.setItem('synapse-desktop.text-size', '3')")
  await page.reload()
  expect(await rootSize(page)).toBe('18px')
})

test('a terminal that is open follows the size of the text', async ({ page }) => {
  await page.goto('/')
  await openLaunch(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  const terminalSize = (): Promise<string | null> =>
    page.evaluate(
      "(document.querySelector('.terminal-view:not([hidden]) .xterm-rows') && getComputedStyle(document.querySelector('.terminal-view:not([hidden]) .xterm-rows')).fontSize)",
    )
  // 13px at the browser size is 15px at the default.
  await expect.poll(terminalSize).toBe('15px')

  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await page.getByRole('combobox', { name: 'Text size' }).selectOption('150')
  // The terminals are kept while another page shows; the page is reopened to see them.
  await page.getByRole('tab', { name: 'Terminals' }).click()
  await expect.poll(terminalSize).toBe('20px')
})
