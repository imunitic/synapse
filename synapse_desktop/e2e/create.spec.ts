import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test } from '@playwright/test'
import { editor, openSection, setEditorText, uniqueName, world } from './helpers.ts'

test('a new pipeline is drawn as it is typed, shows what is wrong, and is saved as a file', async ({
  page,
}) => {
  const name = uniqueName('Created')
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page.getByRole('button', { name: 'New pipeline' }).click()

  await setEditorText(
    page,
    `Pipeline ${name} { First [Harness => Claude, Prompt => "Say hi."]; Second [Harness => Codex, Prompt => "Say bye."]; }`,
  )
  const diagram = page.getByLabel('Diagram')
  await expect(diagram.getByLabel('Step First, Claude')).toBeVisible()
  await expect(diagram.getByLabel('Step Second, Codex')).toBeVisible()

  // Broken text: the problems are said, the last diagram stays, and nothing can be made.
  await setEditorText(page, `Pipeline ${name} { First [Agent => Nobody, Harnes => Claude]; }`)
  const problems = page.getByLabel('Problems')
  await expect(problems).toContainText("there is no agent named 'Nobody'")
  await expect(problems).toContainText("unknown attribute 'Harnes'")
  await expect(page.getByText('Showing the last valid version of the text.')).toBeVisible()
  await expect(diagram.getByLabel('Step Second, Codex')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeDisabled()

  await setEditorText(page, `Pipeline ${name} { Only [Harness => Claude, Prompt => "Do it."]; }`)
  await expect(problems).toContainText('None.')
  await page.getByRole('button', { name: 'Create', exact: true }).click()

  await expect(page.getByRole('heading', { name })).toBeVisible()
  await expect(page.getByRole('tab', { name })).toBeVisible()
  const file = join(world().definitions, `${name}.synapse`)
  expect(existsSync(file)).toBe(true)
  expect(readFileSync(file, 'utf8')).toContain('Only [Harness => Claude')
})

test('a name that is taken is refused', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page.getByRole('button', { name: 'New pipeline' }).click()
  await setEditorText(page, 'Pipeline Develop_Feature { Only [Harness => Claude, Prompt => "x"]; }')
  await expect(page.getByLabel('Problems')).toContainText('already exists')
  await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeDisabled()
})

test('the Name field changes the name in the text, and waits for a name that fits', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page.getByRole('button', { name: 'New pipeline' }).click()
  const field = page.getByRole('textbox', { name: 'Name', exact: true })

  await field.fill('Typed_Name')
  await expect(editor(page)).toContainText('Pipeline Typed_Name {')

  await field.fill('9bad')
  await expect(page.getByText('A name has letters, digits and underscores')).toBeVisible()
  await expect(editor(page)).toContainText('Pipeline Typed_Name {')

  await setEditorText(page, 'Pipeline Written_There { A [Harness => Claude, Prompt => "x"]; }')
  await expect(field).toHaveValue('Written_There')
})
