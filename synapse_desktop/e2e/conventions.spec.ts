import { expect, test, type Page } from '@playwright/test'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

const file = (name: string) => join(world().xdg, 'synapse', name)
const written = [
  'synapse-projects.conf',
  'synapse-tag-vocabulary.conf',
  'synapse-prompt-stopwords.conf',
  'synapse-grammars.conf',
  'synapse-fence-languages.conf',
]

test.beforeEach(() => {
  resetWorldSettings()
  for (const name of written) rmSync(file(name), { force: true })
  writeFileSync(file('synapse-projects.conf'), '# mine\nsynapse=sb\neon=ecs\n')
  writeFileSync(file('synapse-tag-vocabulary.conf'), '# tags\nalpha\nbeta\n')
  writeFileSync(file('synapse-fence-languages.conf'), '{".el": "lisp"}')
})

test.afterEach(() => {
  for (const name of written) rmSync(file(name), { force: true })
  resetWorldSettings()
})

async function openConventions(page: Page) {
  await page.goto('/')
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^Conventions/ })
    .click()
  await expect(page.getByRole('heading', { level: 1, name: 'Conventions' })).toBeVisible()
}

const card = (page: Page, title: string) =>
  page.locator('details.convention', { has: page.locator('.convention-title', { hasText: title }) })

async function open(page: Page, title: string) {
  await card(page, title).locator('summary').click()
  await expect(card(page, title)).toHaveAttribute('open', '')
}

test('the page lists every file in three groups, all closed, with how many entries each has', async ({
  page,
}) => {
  await openConventions(page)
  for (const group of ['Vault', 'Code graph', 'Prompts']) {
    await expect(page.getByRole('heading', { level: 2, name: group })).toBeVisible()
  }
  await expect(page.locator('details.convention')).toHaveCount(11)
  await expect(page.locator('details.convention[open]')).toHaveCount(0)
  await expect(card(page, 'Projects').getByLabel('2 entries')).toBeVisible()
  await expect(card(page, 'Tag vocabulary').getByLabel('2 entries')).toBeVisible()
  await expect(card(page, 'Prompt stopwords').getByLabel('0 entries')).toBeVisible()
  await expect(card(page, 'Fence languages').getByLabel('1 entry')).toBeVisible()
  // Nothing of a closed card is drawn.
  await expect(page.getByRole('list', { name: 'Entries of Projects' })).toHaveCount(0)
})

test('a card opens to its entries and where they are kept, and closes again', async ({ page }) => {
  await openConventions(page)
  await open(page, 'Projects')
  const list = page.getByRole('list', { name: 'Entries of Projects' })
  await expect(list.getByRole('listitem')).toHaveCount(2)
  await expect(list).toContainText('synapse=sb')
  await expect(list).toContainText('eon=ecs')
  await expect(card(page, 'Projects')).toContainText(file('synapse-projects.conf'))

  await card(page, 'Projects').locator('summary').click()
  await expect(card(page, 'Projects')).not.toHaveAttribute('open', '')
  await expect(list).toHaveCount(0)
})

test('a project is added by its name and prefix, and a bad one is refused', async ({ page }) => {
  await openConventions(page)
  await open(page, 'Projects')
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
  await expect(page.getByRole('list', { name: 'Entries of Projects' })).toContainText('thing=tg')
  await expect(card(page, 'Projects').getByLabel('3 entries')).toBeVisible()
  expect(readFileSync(file('synapse-projects.conf'), 'utf8')).toBe(
    '# mine\nsynapse=sb\neon=ecs\nthing=tg\n',
  )
})

test('an entry is added to a file of lines and taken out, and the comments stay', async ({
  page,
}) => {
  await openConventions(page)
  await open(page, 'Tag vocabulary')
  const form = page.getByRole('form', { name: 'Add to Tag vocabulary' })
  await form.getByLabel('New entry of Tag vocabulary').fill('gamma')
  await form.getByRole('button', { name: 'Add' }).click()
  const list = page.getByRole('list', { name: 'Entries of Tag vocabulary' })
  await expect(list).toContainText('gamma')
  expect(readFileSync(file('synapse-tag-vocabulary.conf'), 'utf8')).toBe(
    '# tags\nalpha\nbeta\ngamma\n',
  )
  await expect(form.getByLabel('New entry of Tag vocabulary')).toHaveValue('')

  await form.getByLabel('New entry of Tag vocabulary').fill('alpha')
  await form.getByRole('button', { name: 'Add' }).click()
  await expect(page.getByRole('alert')).toContainText('alpha is already there')

  await list.getByRole('button', { name: 'Remove alpha' }).click()
  await expect(list).not.toContainText('alpha')
  expect(readFileSync(file('synapse-tag-vocabulary.conf'), 'utf8')).toBe('# tags\nbeta\ngamma\n')
})

test('a card that was open stays open after a change and after a reload', async ({ page }) => {
  await openConventions(page)
  await open(page, 'Tag vocabulary')
  const form = page.getByRole('form', { name: 'Add to Tag vocabulary' })
  await form.getByLabel('New entry of Tag vocabulary').fill('delta')
  await form.getByRole('button', { name: 'Add' }).click()
  await expect(card(page, 'Tag vocabulary')).toHaveAttribute('open', '')
  await expect(card(page, 'Projects')).not.toHaveAttribute('open', '')

  await page.reload()
  await openSection(page, 'Settings')
  await sidePanel(page)
    .getByRole('button', { name: /^Conventions/ })
    .click()
  await expect(card(page, 'Tag vocabulary')).toHaveAttribute('open', '')
  await expect(card(page, 'Tag vocabulary')).toContainText('delta')
})

test('a long list has a filter and shows no more than a hundred rows', async ({ page }) => {
  const words = Array.from({ length: 150 }, (_, i) => `word${String(i).padStart(3, '0')}`)
  writeFileSync(file('synapse-prompt-stopwords.conf'), `# words\n${words.join('\n')}\n`)
  await openConventions(page)
  await expect(card(page, 'Prompt stopwords').getByLabel('150 entries')).toBeVisible()
  await open(page, 'Prompt stopwords')
  const list = page.getByRole('list', { name: 'Entries of Prompt stopwords' })
  await expect(list.getByRole('listitem')).toHaveCount(100)
  await expect(card(page, 'Prompt stopwords')).toContainText('Showing 100 of 150')

  await card(page, 'Prompt stopwords').getByLabel('Filter Prompt stopwords').fill('word14')
  await expect(list.getByRole('listitem')).toHaveCount(10)
  await expect(card(page, 'Prompt stopwords')).not.toContainText('Showing')
})

test('a file of JSON is shown as it is and cannot be changed here', async ({ page }) => {
  writeFileSync(file('synapse-grammars.conf'), '{"ml": {"repo": "https://example.test/g"}}')
  writeFileSync(file('synapse-fence-languages.conf'), '{oops')
  await openConventions(page)
  await open(page, 'Grammars')
  const list = page.getByRole('list', { name: 'Entries of Grammars' })
  await expect(list).toContainText('ml')
  await expect(list).toContainText('https://example.test/g')
  await expect(card(page, 'Grammars').getByRole('button', { name: /^Remove/ })).toHaveCount(0)
  await expect(card(page, 'Grammars').getByRole('form')).toHaveCount(0)
  await expect(card(page, 'Grammars')).toContainText('changed in the file itself')

  await open(page, 'Fence languages')
  await expect(card(page, 'Fence languages').getByRole('alert')).toContainText('not JSON')
})

test('a file that is not there yet says where it will be made', async ({ page }) => {
  await openConventions(page)
  await open(page, 'Prompt stopwords')
  await expect(card(page, 'Prompt stopwords')).toContainText('There is no file yet')
  await expect(card(page, 'Prompt stopwords')).toContainText(file('synapse-prompt-stopwords.conf'))
})
