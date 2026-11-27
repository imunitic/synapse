import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { expect, type Page } from '@playwright/test'
import { resetSettings, worldAt, type World } from './world.ts'

// The world of this run of the tests.
export function world(): World {
  const root = process.env.E2E_WORLD
  if (root === undefined) throw new Error('E2E_WORLD is not set')
  return worldAt(root)
}

// A name no other test uses, for a definition a test makes.
export function uniqueName(prefix: string): string {
  return `E2e_${prefix}_${randomBytes(3).toString('hex')}`
}

// The side panel, where the same words may also be on the page beside it.
export function sidePanel(page: Page) {
  return page.getByRole('complementary', { name: 'Side panel' })
}

// Opens the page where a terminal is started, from the rail.
export async function openLaunch(page: Page) {
  await page.getByRole('button', { name: 'Terminals', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Terminals' })).toBeVisible()
}

// The card on that page for a shell or a harness.
export function launchCard(page: Page, name: 'Shell' | 'Claude Code' | 'Codex' | 'OpenCode') {
  return page.getByRole('tabpanel').getByLabel(name, { exact: true })
}

// Opens a section of the rail and its panel, whatever it showed before.
export async function openSection(
  page: Page,
  section: 'Definitions' | 'Executions' | 'Vault' | 'Settings',
) {
  const button = page.getByRole('button', { name: section, exact: true })
  if ((await button.getAttribute('aria-pressed')) !== 'true') await button.click()
  await expect(button).toHaveAttribute('aria-pressed', 'true')
}

// Replaces what is in the editor with text.
export async function setEditorText(page: Page, text: string) {
  await page.locator('.cm-content').click()
  await page.keyboard.press('ControlOrMeta+A')
  await page.keyboard.insertText(text)
}

export function editor(page: Page) {
  return page.locator('.cm-content')
}

// Puts synapse.conf and the app's settings back as the world began.
export function resetWorldSettings(): void {
  resetSettings(world())
}

// Opens a folding card of the execution page, if it is folded, so its rows can be read.
export async function openCard(page: Page, name: 'Outcomes' | 'Trace' | 'Events'): Promise<void> {
  const button = page.getByLabel(name, { exact: true }).locator('.card-fold')
  if ((await button.getAttribute('aria-expanded')) === 'false') await button.click()
  await expect(button).toHaveAttribute('aria-expanded', 'true')
}

// Starts a run without a terminal from the command line, as the run dialog does not, and opens its
// page from the Executions panel. The engine answers with the world's script, so the run goes on in
// the background and ends by itself; its id is returned.
export async function startRunWithoutTerminal(page: Page, pipeline: string): Promise<string> {
  const id = `exec-${randomBytes(4).toString('hex')}`
  spawn('synapse-pipeline', ['run', pipeline, '--id', id], {
    cwd: world().root,
    stdio: 'ignore',
  }).unref()
  await page.goto('/')
  await openSection(page, 'Executions')
  const row = sidePanel(page).locator(`.list-row[data-execution="${id}"] .list-item`)
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()
  await expect(page.getByRole('heading', { level: 1, name: id })).toBeVisible()
  return id
}
