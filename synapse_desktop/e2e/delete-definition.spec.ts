import { expect, test, type Page } from './fixtures.ts'
import { existsSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, sidePanel, world } from './helpers.ts'

type Kind = 'Pipelines' | 'Systems' | 'Agents' | 'Skills'

// The row of a definition in the side panel.
async function rowOf(page: Page, kind: Kind, name: string) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: kind }).click()
  const row = sidePanel(page).locator('.list-entry', { hasText: name })
  await expect(row).toBeVisible()
  return row
}

test('a definition nothing uses is deleted after it is asked for twice', async ({ page }) => {
  const idle = join(world().definitions, 'Idle_To_Delete.synapse')
  writeFileSync(idle, 'Agent Idle_To_Delete [Prompt => "Wait."];\n')
  try {
    const row = await rowOf(page, 'Agents', 'Idle_To_Delete')
    await row.getByRole('button', { name: 'Delete this agent' }).click()
    const sure = row.getByRole('alertdialog', { name: 'Are you sure?' })
    await expect(sure).toContainText('Idle_To_Delete')

    // Cancelling leaves it.
    await sure.getByRole('button', { name: 'Cancel' }).click()
    await expect(sure).toHaveCount(0)
    expect(existsSync(idle)).toBe(true)

    await row.getByRole('button', { name: 'Delete this agent' }).click()
    await sure.getByRole('button', { name: 'Yes, delete' }).click()
    await expect(sidePanel(page).locator('.list-entry', { hasText: 'Idle_To_Delete' })).toHaveCount(
      0,
    )
    expect(existsSync(idle)).toBe(false)
  } finally {
    rmSync(idle, { force: true })
  }
})

test('an agent a system uses is not deleted, and the system is named', async ({ page }) => {
  const row = await rowOf(page, 'Agents', 'Reviewer')
  await row.getByRole('button', { name: 'Delete this agent' }).click()
  const refusal = row.getByRole('alert')
  await expect(refusal).toContainText('cannot be deleted yet')
  await expect(refusal).toContainText('Strict_Reviewer')
  await expect(row.getByRole('button', { name: 'Yes, delete' })).toHaveCount(0)
  expect(existsSync(join(world().definitions, 'Reviewer.synapse'))).toBe(true)
})

test('a system a pipeline uses is not deleted, and the pipeline is named', async ({ page }) => {
  const row = await rowOf(page, 'Systems', 'Strict_Reviewer')
  await row.getByRole('button', { name: 'Delete this system' }).click()
  const refusal = row.getByRole('alert')
  await expect(refusal).toContainText('Develop_Feature')
  await expect(refusal).toContainText('step Review')
})

test('a skill a step, an agent or a system names is not deleted', async ({ page }) => {
  const row = await rowOf(page, 'Skills', 'review-code')
  await row.getByRole('button', { name: 'Delete this skill' }).click()
  const refusal = row.getByRole('alert')
  await expect(refusal).toContainText('Strict_Reviewer')
  expect(existsSync(join(world().definitions, 'skills', 'review-code', 'SKILL.md'))).toBe(true)
})
