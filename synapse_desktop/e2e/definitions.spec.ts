import { expect, test } from '@playwright/test'
import { sidePanel } from './helpers.ts'

test('the definitions are narrowed by what is typed in the filter, in any case', async ({
  page,
}) => {
  await page.goto('/')
  const panel = sidePanel(page)
  const filter = panel.getByRole('searchbox', { name: 'Filter the pipelines' })
  await expect(panel.getByRole('button', { name: /Develop_Feature/ })).toBeVisible()
  await expect(panel.getByRole('button', { name: /Fixture_Run/ })).toBeVisible()

  await filter.fill('FIXTURE')
  await expect(panel.getByRole('button', { name: /Fixture_Run/ })).toBeVisible()
  await expect(panel.getByRole('button', { name: /Develop_Feature/ })).toHaveCount(0)

  await filter.fill('nothing like it')
  await expect(panel).toContainText('No pipelines match “nothing like it”.')

  await filter.fill('')
  await expect(panel.getByRole('button', { name: /Develop_Feature/ })).toBeVisible()
})

test('the filter stays when the kind of definition changes, and its label says which kind', async ({
  page,
}) => {
  await page.goto('/')
  const panel = sidePanel(page)
  await panel.getByRole('searchbox', { name: 'Filter the pipelines' }).fill('zzz')
  await panel.getByRole('button', { name: 'Agents' }).click()
  const agents = panel.getByRole('searchbox', { name: 'Filter the agents' })
  await expect(agents).toHaveValue('zzz')
})
