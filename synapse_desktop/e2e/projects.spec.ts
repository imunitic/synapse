import { expect, test, type Page } from '@playwright/test'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

const projectsFile = () => join(world().xdg, 'synapse', 'synapse-projects.conf')

test.beforeEach(() => {
  resetWorldSettings()
  writeFileSync(projectsFile(), '# mine\nsynapse=sb\neon=ecs\n')
})

test.afterEach(() => {
  rmSync(projectsFile(), { force: true })
  resetWorldSettings()
})

async function openProjects(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^Projects/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'Projects' })).toBeVisible()
}

test('the Projects page of the settings lists the projects, and where they are kept', async ({
  page,
}) => {
  await openProjects(page)
  const list = page.getByRole('list', { name: 'The projects' })
  await expect(list.getByRole('listitem')).toHaveCount(2)
  await expect(list).toContainText('synapse')
  await expect(list).toContainText('sb')
  await expect(list).toContainText('eon')
  await expect(page.getByLabel('Projects', { exact: true })).toContainText(projectsFile())
})

test('a project added by hand is saved in the file and listed, and a bad one is refused', async ({
  page,
}) => {
  await openProjects(page)
  const form = page.getByRole('form', { name: 'New project' })
  await form.getByLabel('Project name').fill('Not Right')
  await form.getByLabel('Project prefix').fill('nr')
  await form.getByRole('button', { name: 'Add' }).click()
  await expect(page.getByRole('alert')).toContainText('lower case')

  await form.getByLabel('Project name').fill('thing')
  await form.getByLabel('Project prefix').fill('sb')
  await form.getByRole('button', { name: 'Add' }).click()
  await expect(page.getByRole('alert')).toContainText(
    'The prefix sb is already the prefix of synapse',
  )

  await form.getByLabel('Project prefix').fill('tg')
  await form.getByRole('button', { name: 'Add' }).click()
  const list = page.getByRole('list', { name: 'The projects' })
  await expect(list.getByRole('listitem')).toHaveCount(3)
  await expect(list).toContainText('thing')
  expect(readFileSync(projectsFile(), 'utf8')).toBe('# mine\nsynapse=sb\neon=ecs\nthing=tg\n')
  // The form is empty again for the next one.
  await expect(form.getByLabel('Project name')).toHaveValue('')
})

test('with no project the page says so', async ({ page }) => {
  writeFileSync(projectsFile(), '# nothing yet\n')
  await openProjects(page)
  await expect(page.getByText('No project is set yet.')).toBeVisible()
})
