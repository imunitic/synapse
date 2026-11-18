import { expect, test, type Page } from './fixtures.ts'
import { launchCard, openLaunch, openSection, resetWorldSettings, sidePanel } from './helpers.ts'

test.beforeEach(() => resetWorldSettings())
test.afterEach(() => resetWorldSettings())

// The browser's own functions are named in strings, since the tests are not typed for a page.
const theme = (page: Page): Promise<string> =>
  page.evaluate('document.documentElement.dataset.theme')
const ground = (page: Page): Promise<string> =>
  page.evaluate('getComputedStyle(document.body).backgroundColor')

async function openGeneral(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^General/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()
}

test('the app is dark by default', async ({ page }) => {
  await openGeneral(page)
  await expect(page.getByRole('combobox', { name: 'Theme' })).toHaveValue('dark')
  expect(await theme(page)).toBe('dark')
  expect(await ground(page)).toBe('rgb(27, 27, 31)')
})

test('the Theme setting turns the whole app light at once and is kept after a reload', async ({
  page,
}) => {
  await openGeneral(page)
  const choice = page.getByRole('combobox', { name: 'Theme' })
  await expect(choice.locator('option')).toHaveText(['Dark', 'Light', 'System'])

  await choice.selectOption('light')
  expect(await theme(page)).toBe('light')
  expect(await ground(page)).toBe('rgb(244, 244, 245)')

  await page.reload()
  expect(await theme(page)).toBe('light')
  await openGeneral(page)
  await expect(page.getByRole('combobox', { name: 'Theme' })).toHaveValue('light')
})

test('System follows the computer, and changes when it does', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' })
  await openGeneral(page)
  await page.getByRole('combobox', { name: 'Theme' }).selectOption('system')
  expect(await theme(page)).toBe('light')
  await page.emulateMedia({ colorScheme: 'dark' })
  await expect.poll(() => theme(page)).toBe('dark')
})

test('a terminal stays dark in the light theme, a softer dark than in the dark one', async ({
  page,
}) => {
  await openGeneral(page)
  await page.getByRole('combobox', { name: 'Theme' }).selectOption('light')
  await openLaunch(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  const host = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await expect(host).toHaveCSS('background-color', 'rgb(54, 58, 66)')
  // xterm.js 6 paints the theme's background on its scrollable element; the viewport keeps the
  // black of xterm.css under it.
  await expect(host.locator('.xterm-scrollable-element')).toHaveCSS(
    'background-color',
    'rgb(54, 58, 66)',
  )
  await page.getByRole('button', { name: 'Close Shell 1' }).click()
})
