import { expect, test, type Page } from '@playwright/test'
import { rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, sidePanel, world } from './helpers.ts'

async function openDefinition(page: Page, kind: 'Pipelines' | 'Systems' | 'Agents', name: RegExp) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: kind }).click()
  await sidePanel(page).getByRole('button', { name }).click()
}

test('a system page lists its attributes as written and the pipeline step that uses it', async ({
  page,
}) => {
  await openDefinition(page, 'Systems', /Strict_Reviewer/)
  const attributes = page.getByLabel('Attributes')
  await expect(attributes).toContainText('Agent')
  await expect(attributes).toContainText('Reviewer')
  await expect(attributes).toContainText('Codex')
  await expect(attributes).toContainText('review-code')

  const used = page.getByLabel('Used by')
  await expect(used).toContainText('Develop_Feature')
  await expect(used).toContainText('step Review')
  // The pipeline is a link to its page.
  await used.getByRole('button', { name: 'Develop_Feature' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Develop_Feature' })).toBeVisible()
})

test('an agent page says which system uses it', async ({ page }) => {
  await openDefinition(page, 'Agents', /Reviewer/)
  await expect(page.getByLabel('Attributes')).toContainText('You are a reviewer')
  const used = page.getByLabel('Used by')
  await expect(used.getByRole('button', { name: 'Strict_Reviewer' })).toBeVisible()
  await expect(used).toContainText('system')
})

test('an agent that nothing uses says so', async ({ page }) => {
  const idle = join(world().definitions, 'Idle_Agent.synapse')
  writeFileSync(idle, 'Agent Idle_Agent [Prompt => "Wait."];\n')
  try {
    await openDefinition(page, 'Agents', /Idle_Agent/)
    await expect(page.getByLabel('Used by')).toContainText('No pipeline or system uses this agent')
  } finally {
    rmSync(idle, { force: true })
  }
})

test('a step page shows the prompt it is started with, and a later step has a slot for the one before', async ({
  page,
}) => {
  await openDefinition(page, 'Pipelines', /Develop_Feature/)
  // The first step is selected: its role and assignment, and nothing came before it.
  await page.getByText('The prompt', { exact: true }).click()
  const prompt = page.locator('.prompt-text')
  await expect(prompt).toContainText('You are a developer')
  await expect(prompt).toContainText('You are running as the step Develop')
  await expect(prompt).not.toContainText('reported this result')

  // The prompt stays open when another step is chosen, and follows it.
  await page.getByRole('button', { name: /^Step Review/ }).click()
  await expect(page.locator('.prompt-text')).toContainText('You are a reviewer')
  await expect(page.locator('.prompt-text')).toContainText(
    'The step before yours reported this result',
  )
})

test('the run dialog shows the first step prompt with the input that is typed', async ({
  page,
}) => {
  await openDefinition(page, 'Pipelines', /Develop_Feature/)
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByText('The prompt of the first step, with this input').click()
  await expect(dialog.locator('.prompt-text')).toContainText('You are running as the step Develop')

  await dialog.getByLabel('Input (JSON), handed to the first step').fill('{"issue": 7}')
  await expect(dialog.locator('.prompt-text')).toContainText('{"issue":7}')

  // Input that is not JSON is said so, and nothing is started by looking.
  await dialog.getByLabel('Input (JSON), handed to the first step').fill('{oops')
  await expect(dialog).toContainText('is not JSON')
  await expect(dialog.locator('.prompt-text')).toHaveCount(0)
})

test('a file that does not load is listed under the definitions, and the others still are', async ({
  page,
}) => {
  const broken = join(world().definitions, 'Broken_File.synapse')
  writeFileSync(broken, 'Pipeline Broken_File { A [')
  try {
    await page.goto('/')
    await openSection(page, 'Definitions')
    const panel = sidePanel(page)
    await expect(panel.getByRole('button', { name: /Develop_Feature/ })).toBeVisible()
    const problems = panel.getByLabel('Files that did not load')
    await expect(problems).toContainText('Broken_File.synapse')
    await expect(problems).toContainText('expected')
  } finally {
    rmSync(broken, { force: true })
  }
})

test('a step that declares outcomes shows them with their meanings, and its prompt lists them', async ({
  page,
}) => {
  const judged = join(world().definitions, 'Judged_Pipeline.synapse')
  writeFileSync(
    judged,
    `Pipeline Judged_Pipeline {
   Judge [Harness => Claude, Prompt => "Judge the change.",
          Outcomes => {"Approved": "Every requirement is met.", "Rejected": "A requirement is unmet."}];
   Fix [Harness => Claude, Prompt => "Fix it."];
   Judge -> Fix [When => Rejected];
}
`,
  )
  try {
    await openDefinition(page, 'Pipelines', /Judged_Pipeline/)
    const step = page.getByRole('region', { name: 'Step Judge' })
    await expect(step).toContainText('Approved')
    await expect(step).toContainText('Every requirement is met.')
    await expect(step).toContainText('Rejected')
    // Nothing warns about the outcome the edge waits for, which the step declares.
    await expect(step).not.toContainText("not named in this step's instructions")

    await page.getByText('The prompt', { exact: true }).click()
    const prompt = page.locator('.prompt-text')
    await expect(prompt).toContainText('- Approved: Every requirement is met.')
    await expect(prompt).toContainText('- Rejected: A requirement is unmet.')

    // The next step declares none, and says it may end with any word.
    await page.getByRole('button', { name: /^Step Fix/ }).click()
    await expect(page.getByRole('region', { name: 'Step Fix' })).toContainText('any word')
  } finally {
    rmSync(judged, { force: true })
  }
})
