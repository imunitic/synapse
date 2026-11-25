import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test } from './fixtures.ts'

// The stub `claude` answers `/usage` with this fixture. The stub `codex` app-server exits at
// once and the stub `opencode` says it is 0.0.0, so those two come out unavailable.
const fixture = JSON.parse(
  readFileSync(join(import.meta.dirname, '..', 'shared', 'examples', '_usage-claude.json'), 'utf8'),
) as { result: string }

// Every window line of the fixture, as the status bar reads it.
const windows = fixture.result
  .split('\n')
  .map((line) => /^(.+?): (\d+(?:\.\d+)?)% used · resets /.exec(line))
  .filter((match) => match !== null)
  .map((match) => ({ name: match[1], percent: Number(match[2]) }))

const deciding = windows.filter(
  (window) => window.name === 'Current session' || window.name === 'Current week (all models)',
)
const highest = Math.round(Math.max(...deciding.map((window) => window.percent)))
const band = highest <= 50 ? 'green' : highest <= 85 ? 'orange' : 'red'

// The event comes once all three harnesses are read; the stub Codex app-server exits at once.
const READ_MS = 15_000

test('shows the Claude usage in the status bar and every window in its panel', async ({ page }) => {
  expect(deciding).toHaveLength(2)
  await page.goto('/')

  const usage = page.locator('.statusbar-usage')
  const items = usage.getByRole('button')
  const claude = usage.getByRole('button', { name: /^Claude:/ })
  await expect(claude).toBeVisible({ timeout: READ_MS })
  await expect(items).toHaveCount(1)
  await expect(claude).toHaveText(`Claude ${highest}%`)
  await expect(claude.locator('.usage-dot')).toHaveClass(new RegExp(`usage-dot-${band}`))
  await expect(usage.getByRole('button', { name: /^Codex:/ })).toHaveCount(0)
  await expect(usage.getByRole('button', { name: /^Opencode:/ })).toHaveCount(0)
  await expect(usage.locator('.mono')).toHaveCount(0)

  await claude.click()
  const panel = page.getByRole('dialog', { name: 'Harness usage' })
  await expect(panel).toBeVisible()
  const claudeSection = panel.getByRole('region', { name: 'Claude' })
  for (const window of windows) {
    const row = claudeSection.getByRole('listitem').filter({ hasText: window.name })
    await expect(row).toContainText(`${Math.round(window.percent)}%`)
  }
  for (const harness of ['Codex', 'Opencode']) {
    const section = panel.getByRole('region', { name: harness })
    await expect(section.locator('.usage-state')).toHaveText('unavailable')
    await expect(section.locator('.usage-reason')).not.toBeEmpty()
  }

  await page.keyboard.press('Escape')
  await expect(panel).toBeHidden()
})
