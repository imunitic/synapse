import { expect, test } from './fixtures.ts'
import { sidePanel } from './helpers.ts'

test('the definitions are narrowed by what is typed in the filter, in any case', async ({
  page,
}) => {
  await page.goto('/')
  const panel = sidePanel(page)
  const filter = panel.getByRole('searchbox', { name: 'Filter the pipelines' })
  await expect(panel.getByRole('button', { name: 'Develop_Feature', exact: true })).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Fixture_Run', exact: true })).toBeVisible()

  await filter.fill('FIXTURE')
  await expect(panel.getByRole('button', { name: 'Fixture_Run', exact: true })).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Develop_Feature', exact: true })).toHaveCount(0)

  await filter.fill('nothing like it')
  await expect(panel).toContainText('No pipelines match “nothing like it”.')

  await filter.fill('')
  await expect(panel.getByRole('button', { name: 'Develop_Feature', exact: true })).toBeVisible()
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

test('prompts have a tab of their own', async ({ page }) => {
  await page.goto('/')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'Prompts', exact: true }).click()
  await expect(panel.getByRole('searchbox', { name: 'Filter the prompts' })).toBeVisible()
  // Its description is read with its name.
  await expect(
    panel.getByRole('button', {
      name: 'Test_Feature Run the tests for a feature and report which ones fail.',
    }),
  ).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Review_Code', exact: true })).toBeVisible()
  await expect(panel.getByRole('button', { name: 'Developer', exact: true })).toHaveCount(0)
})
