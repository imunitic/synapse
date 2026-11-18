import { expect, test } from './fixtures.ts'
import { overrideBus } from './bus.ts'
import { launchCard, openLaunch, openSection } from './helpers.ts'

test('a host that offers a shell has the buttons that start one', async ({ page }) => {
  await page.goto('/')
  await expect(
    page.getByRole('group', { name: 'Quick actions' }).getByRole('button', { name: 'New shell' }),
  ).toBeVisible()
  await openLaunch(page)
  await expect(launchCard(page, 'Shell')).toBeVisible()
})

test('a host that offers no shell has no New shell button, on any page', async ({ page }) => {
  await overrideBus(page, {}, { capabilities: { shell: false } })
  await page.goto('/')
  await expect(page.getByRole('group', { name: 'Quick actions' })).toBeVisible()
  await expect(
    page.getByRole('group', { name: 'Quick actions' }).getByRole('button', { name: 'New shell' }),
  ).toHaveCount(0)
  await openLaunch(page)
  await expect(page.getByRole('heading', { level: 1, name: 'Terminals' })).toBeVisible()
  await expect(launchCard(page, 'Shell')).toHaveCount(0)
  // A harness still starts, in a terminal of its own.
  await expect(launchCard(page, 'Claude Code')).toBeVisible()
})

test('a host that does not install into the harnesses offers no install button', async ({
  page,
}) => {
  await overrideBus(page, {}, { capabilities: { installActions: false } })
  await page.goto('/')
  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'Integrations' }).click()
  await expect(page.getByText('does not install into the harnesses from the app')).toBeVisible()
  await expect(page.getByRole('button', { name: /^(Install|Update|Reinstall)/ })).toHaveCount(0)
})
