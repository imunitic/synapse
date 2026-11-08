import { expect, test } from '@playwright/test'
import { openSection } from './helpers.ts'

test('a run is started from a pipeline and followed to its end', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: /Develop_Feature/ })
    .click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  await page.getByRole('button', { name: 'Start run' }).click()

  // The page of the execution, which goes through the loop once.
  await expect(page.getByText('Execution', { exact: true })).toBeVisible()
  await expect(
    page.locator('.content').getByText('completed', { exact: true }).first(),
  ).toBeVisible({
    timeout: 30_000,
  })
  const trace = page.getByLabel('Trace')
  await expect(trace).toContainText('Changes_Requested → Develop')
  await expect(trace).toContainText('Approved → the run completes')
  // A scripted run has no session, and says so.
  await expect(trace.getByText('no transcript').first()).toBeVisible()
})

test('what an agent did in a step is read from its transcript', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Executions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: /exec-fixture1/ })
    .click()
  await page.getByRole('button', { name: 'Activity' }).click()

  const activity = page.getByLabel('Trace')
  await expect(activity).toContainText('Claude · 3 turns · 5.0 s · $0.12')
  await expect(activity.getByLabel('Files changed')).toContainText('+ result.txt')
  // Each action is a title and what it was done to, with paths shown without
  // the folder the session worked in.
  const actions = activity.locator('.activity-row')
  await expect(actions).toHaveCount(4)
  await expect(actions.nth(0)).toContainText('Read')
  await expect(actions.nth(0).locator('.activity-target')).toHaveText('notes.txt')
  await expect(actions.nth(1)).toContainText('Wrote')
  await expect(actions.nth(1).locator('.activity-target')).toHaveText('result.txt')
  await expect(actions.nth(2).locator('.activity-target')).toHaveText('ls')
  await expect(actions.nth(3)).toContainText('Wrote the word.')
  await page.getByRole('button', { name: 'Hide activity' }).click()
  await expect(actions).toHaveCount(0)
})
