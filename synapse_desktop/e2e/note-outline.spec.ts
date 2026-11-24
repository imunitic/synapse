import { expect, test, type Page } from './fixtures.ts'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  launchCard,
  openLaunch,
  openSection,
  resetWorldSettings,
  sidePanel,
  world,
} from './helpers.ts'

let vault = ''

const TARGET = [
  '---',
  'title: Target',
  'updated: 2026-01-01T00:00:00+00:00',
  '---',
  '# Target',
  '',
  'First line.',
  '',
  '## Evidence',
  '',
  'What was seen.',
  '',
  '### Detail',
  '',
  'A detail.',
  '',
  ...Array.from({ length: 60 }, (_, i) => `Filler line ${i + 1}.\n`),
  '## Fix',
  '',
  'What to do.',
  '',
].join('\n')

const NODE = '---\ntitle: Node\n---\n# Node\n\n## Purpose\n\nA node.\n'

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'note-outline-vault')
  mkdirSync(join(vault, 'research'), { recursive: true })
  mkdirSync(join(vault, 'synapse', 'widget@main'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(join(vault, 'research', 'Target.md'), TARGET)
  writeFileSync(join(vault, 'synapse', 'widget@main', 'Node.md'), NODE)
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  resetWorldSettings()
})

const outline = (page: Page) => page.getByRole('complementary', { name: 'Outline' })
const headings = (page: Page) => outline(page).getByRole('navigation', { name: 'Headings' })
const bar = (page: Page) => page.getByRole('region', { name: 'Note review' })
const outlineToggle = (page: Page) =>
  page.getByRole('button', { name: /^Show or hide the outline/ })

async function openTarget(page: Page) {
  await page.goto('/')
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'research' }).click()
  await panel.getByRole('button', { name: 'Target' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Target' })).toBeVisible()
  await outlineToggle(page).click()
  await expect(headings(page)).toBeVisible()
}

// Writes a comment in the box that is open and saves it.
async function writeComment(page: Page, box: string, text: string) {
  const region = page.getByRole('region', { name: box })
  await region.getByLabel('Comment').fill(text)
  await region.getByRole('button', { name: 'Save' }).click()
  await expect(region).toHaveCount(0)
}

// Three comments: on Evidence from the outline, on Fix from its heading in the body, and on the
// whole note.
async function commentThree(page: Page) {
  await headings(page).getByRole('button', { name: 'Comment on Evidence' }).click()
  await writeComment(page, 'Comment on Target::Evidence', 'Say where it was seen')
  await page
    .locator('.note-heading[data-section="Target::Fix"]')
    .getByRole('button', { name: 'Comment' })
    .click()
  await writeComment(page, 'Comment on Target::Fix', 'Name the owner')
  await page.getByRole('button', { name: 'Comment on the whole note' }).click()
  await writeComment(page, 'Comment on the whole note', 'Shorten it')
  await expect(bar(page).getByRole('button', { name: '3 comments' })).toBeVisible()
}

test('the sidebar of a note is its outline, with the headings nested, and a heading scrolls the note to it', async ({
  page,
}) => {
  await openTarget(page)
  await expect(page.getByRole('complementary', { name: 'Changes' })).toHaveCount(0)
  const target = headings(page).locator(':scope > ul > li')
  await expect(target).toHaveCount(1)
  await expect(target.locator(':scope > .outline-row')).toContainText('Target')
  const sections = target.locator(':scope > ul > li')
  await expect(sections).toHaveCount(2)
  await expect(sections.nth(0).locator(':scope > .outline-row')).toContainText('Evidence')
  await expect(sections.nth(0).locator(':scope > ul > li')).toHaveText(/Detail/)
  await expect(sections.nth(1).locator(':scope > .outline-row')).toContainText('Fix')

  const fix = page.getByRole('heading', { level: 2, name: 'Fix' })
  await expect(fix).not.toBeInViewport()
  await headings(page).getByRole('button', { name: 'Fix', exact: true }).click()
  await expect(fix).toBeInViewport()
})

test('comments from the outline, a heading and the whole note gather in the review, which can be edited, kept over a reload and discarded', async ({
  page,
}) => {
  await openTarget(page)
  await commentThree(page)
  await expect(
    headings(page).locator('.outline-row', { hasText: 'Evidence' }).getByLabel('1 comment'),
  ).toBeVisible()
  await expect(outlineToggle(page)).toHaveAccessibleName('Show or hide the outline: 3 comments')

  await bar(page).getByRole('button', { name: '3 comments' }).click()
  const items = bar(page).locator('.review-item')
  await expect(items).toHaveCount(3)
  await expect(items.nth(0)).toContainText('Target::Evidence')
  await expect(items.nth(1)).toContainText('Target::Fix')
  await expect(items.nth(2)).toContainText('Whole note')

  await items.nth(0).getByRole('button', { name: 'Edit' }).click()
  await items.nth(0).getByLabel('Comment').fill('Say where and when it was seen')
  await items.nth(0).getByRole('button', { name: 'Save' }).click()
  await expect(items.nth(0)).toContainText('Say where and when it was seen')

  await items.nth(1).getByRole('button', { name: 'Remove' }).click()
  await expect(items).toHaveCount(2)
  await expect(bar(page).getByRole('button', { name: '2 comments' })).toBeVisible()

  // The review is kept over a reload of the app.
  await page.reload()
  await openTarget(page)
  await expect(bar(page).getByRole('button', { name: '2 comments' })).toBeVisible()
  await bar(page).getByRole('button', { name: '2 comments' }).click()
  await expect(bar(page)).toContainText('Say where and when it was seen')

  await bar(page).getByRole('button', { name: 'Discard' }).click()
  await expect(bar(page)).toHaveCount(0)
  await expect(headings(page).locator('.outline-count')).toHaveCount(0)
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
})

test('Send to agent changes the note in one run, shows what it did, and the review is gone', async ({
  page,
}) => {
  await openTarget(page)
  await commentThree(page)
  await bar(page).getByRole('button', { name: 'Send to agent' }).click()

  const result = page.getByRole('region', { name: 'What the change did' })
  await expect(result).toContainText('The note is changed')
  await expect(bar(page)).toHaveCount(0)
  const written = readFileSync(join(vault, 'research', 'Target.md'), 'utf8')
  expect(written).toContain('Stub edit:')
  expect(written).toContain('Section: Target::Evidence')
  expect(written).toContain('Whole note')
})

test('when the agent leaves the note unchanged the comments stay and the failure is shown', async ({
  page,
}) => {
  await openTarget(page)
  await headings(page).getByRole('button', { name: 'Comment on Fix' }).click()
  await writeComment(page, 'Comment on Target::Fix', 'NOCHANGE')
  await bar(page).getByRole('button', { name: 'Send to agent' }).click()

  await expect(bar(page).getByRole('alert')).toContainText('The note was not changed.')
  await expect(bar(page).getByRole('button', { name: '1 comment' })).toBeVisible()
  expect(readFileSync(join(vault, 'research', 'Target.md'), 'utf8')).toBe(TARGET)
})

test('two sibling headings with the same title are both listed but offer no comment', async ({
  page,
}) => {
  writeFileSync(join(vault, 'research', 'Target.md'), `${TARGET}## Fix\n\nA second fix.\n`)
  await openTarget(page)
  const fixes = headings(page).locator('.outline-row', { hasText: 'Fix' })
  await expect(fixes).toHaveCount(2)
  await expect(headings(page).getByRole('button', { name: 'Comment on Fix' })).toHaveCount(0)
  await expect(headings(page).getByRole('button', { name: 'Comment on Evidence' })).toBeVisible()
  const bodyFixes = page.locator('.note-heading[data-section="Target::Fix"]')
  await expect(bodyFixes).toHaveCount(2)
  await expect(bodyFixes.getByRole('button', { name: 'Comment' })).toHaveCount(0)
})

test('a heading with inline markdown can be commented on from the outline and from the body, and the stripped H1 from the outline', async ({
  page,
}) => {
  writeFileSync(
    join(vault, 'research', 'Target.md'),
    `${TARGET}## Use \`vault-doc-map\` and *care*\n\nCode in a heading.\n`,
  )
  await openTarget(page)
  const section = 'Target::Use `vault-doc-map` and *care*'
  const row = headings(page).locator('.outline-row', { hasText: 'Use vault-doc-map and care' })
  await expect(row).toBeVisible()

  // From the outline: the heading scrolls the note to it, and Comment opens the box under it.
  const body = page.locator('.note-heading').filter({ hasText: 'Use vault-doc-map and care' })
  await expect(body).toHaveAttribute('data-section', section)
  await row.getByRole('button', { name: 'Use vault-doc-map and care', exact: true }).click()
  await expect(body).toBeInViewport()
  await row.getByRole('button', { name: 'Comment on Use vault-doc-map and care' }).click()
  await writeComment(page, `Comment on ${section}`, 'From the outline')

  // From the body heading.
  await body.getByRole('button', { name: 'Comment' }).click()
  await writeComment(page, `Comment on ${section}`, 'From the body')

  // The H1 the page strips has no body heading: its comment box opens at the top.
  await headings(page).getByRole('button', { name: 'Comment on Target' }).click()
  await writeComment(page, 'Comment on Target', 'On the title')

  await bar(page).getByRole('button', { name: '3 comments' }).click()
  const items = bar(page).locator('.review-item')
  await expect(items).toHaveCount(3)
  await expect(items.nth(0)).toContainText(section)
  await expect(items.nth(1)).toContainText(section)
  await expect(items.nth(2)).toContainText('Target')
  await expect(items.nth(2)).not.toContainText('no longer in the note')
})

test('a node of a code graph shows its outline but offers no comments', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  await panel.getByRole('button', { name: 'synapse' }).click()
  await panel.getByRole('button', { name: 'widget@main' }).click()
  await panel.getByRole('button', { name: 'Node' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Node' })).toBeVisible()
  await outlineToggle(page).click()

  await expect(headings(page).getByRole('button', { name: 'Purpose', exact: true })).toBeVisible()
  await expect(outline(page).getByRole('button', { name: /^Comment/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Comment on the whole note' })).toHaveCount(0)
  await expect(page.locator('.note-heading-comment')).toHaveCount(0)
  await expect(bar(page)).toHaveCount(0)
})

test('the page of a terminal session still has the Changes sidebar', async ({ page }) => {
  const dir = mkdtempSync(join(tmpdir(), 'sd-note-outline-'))
  try {
    await page.goto('/')
    await openLaunch(page)
    await page.getByLabel('Start in').fill(dir)
    await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
    await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()

    await expect(outlineToggle(page)).toHaveCount(0)
    await page.getByRole('button', { name: /^Show or hide the changes/ }).click()
    await expect(page.getByRole('complementary', { name: 'Changes' })).toBeVisible()
    await expect(outline(page)).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
