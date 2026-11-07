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

// Opens a section of the rail and its panel, whatever it showed before.
export async function openSection(page: Page, section: 'Definitions' | 'Executions' | 'Settings') {
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
