import { expect, test } from './fixtures.ts'
import { openSection, sidePanel } from './helpers.ts'

// A headless run of Live_Run: its step says something, edits a.txt and then takes about twelve
// seconds before it answers. The test looks at the page while the step runs.
test('a running step is followed on its page and in the Changes sidebar', async ({ page }) => {
  test.setTimeout(120_000)
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'Live_Run', exact: true }).click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  await expect(page.getByLabel(/Run without a terminal/)).toBeEnabled()
  await page.getByLabel(/Run without a terminal/).check()
  await page.getByRole('button', { name: 'Start run' }).click()

  // The card of the running step shows what the agent has done so far, before the step ends.
  const card = page.getByRole('region', { name: 'Live step' })
  await expect(card).toContainText('Running: Work', { timeout: 30_000 })
  await expect(card).toContainText('Looking at a.txt.', { timeout: 30_000 })
  await expect(card.locator('.activity-row').first()).toBeVisible()
  await expect(card).toBeVisible()

  // The Changes sidebar shows the file the step has changed, while it still runs.
  await page.getByRole('button', { name: /^Show or hide the changes/ }).click()
  const sidebar = page.getByRole('complementary', { name: 'Changes' })
  await expect(sidebar).toContainText('a.txt', { timeout: 30_000 })
  await expect(card).toBeVisible()

  // Refresh reads them again, and the file is still there.
  await sidebar.getByRole('button', { name: 'Refresh', exact: true }).click()
  await expect(sidebar).toContainText('a.txt')
  await expect(card).toBeVisible()

  // When the step ends the card goes, and the changes stay as the step's recorded patch.
  await expect(card).toHaveCount(0, { timeout: 60_000 })
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({ timeout: 30_000 })
  await expect(sidebar).toContainText('a.txt')
})
