import { expect, test, type Page } from './fixtures.ts'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { openSection, resetWorldSettings, sidePanel, world } from './helpers.ts'

let vault = ''

// The projects a note may name, which the program checks a write against.
const projects = () => join(world().xdg, 'synapse', 'synapse-projects.conf')

const TASK = `---
schema: vault-task-note/v1
title: "Make the widget"
project: sb
task_id: sb-901
created: "2026-01-01T00:00:00+00:00"
updated: 2026-01-01T00:00:00+00:00
tags: []
status: REVIEW
---

# Make the widget

Make the widget work.

## Checklist

- [x] Make it

## Notes

Done by hand.
`

const PLAIN = '---\ntitle: Plain\nupdated: 2026-01-01T00:00:00+00:00\n---\n# Plain\n\nNot a task.\n'

test.beforeEach(() => {
  resetWorldSettings()
  vault = join(world().root, 'task-status-vault')
  mkdirSync(join(vault, 'tasks', 'p'), { recursive: true })
  mkdirSync(join(vault, 'research'), { recursive: true })
  writeFileSync(join(vault, 'Index.md'), '# Index\n')
  writeFileSync(join(vault, 'tasks', 'p', 'Make the widget.md'), TASK)
  writeFileSync(join(vault, 'research', 'Plain.md'), PLAIN)
  writeFileSync(projects(), 'synapse=sb\n')
  writeFileSync(world().conf, `${readFileSync(world().conf, 'utf8')}SYNAPSE_VAULT_DIR=${vault}\n`)
})

test.afterEach(() => {
  rmSync(vault, { recursive: true, force: true })
  rmSync(projects(), { force: true })
  resetWorldSettings()
})

async function openNote(page: Page, folders: string[], name: string) {
  await page.goto('/')
  await openSection(page, 'Vault')
  const panel = sidePanel(page)
  for (const folder of folders) await panel.getByRole('button', { name: folder }).click()
  await panel.getByRole('button', { name }).click()
  await expect(page.getByRole('heading', { level: 1, name })).toBeVisible()
}

const onDisk = () => readFileSync(join(vault, 'tasks', 'p', 'Make the widget.md'), 'utf8')

test('a person marks a task note as done from its page, and can undo it', async ({ page }) => {
  await openNote(page, ['tasks', 'p'], 'Make the widget')
  const mark = page.getByRole('button', { name: 'Mark as done' })
  await expect(mark).toBeVisible()
  await expect(page.getByLabel('Properties')).toContainText('REVIEW')

  await mark.click()
  // The check is filled, and pressing it again undoes it.
  const undo = page.getByRole('button', { name: 'Undo marking as done' })
  await expect(undo).toBeVisible()
  await expect(undo).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByLabel('Properties')).toContainText('DONE')
  await expect(mark).toHaveCount(0)
  // Only the status and the time it was updated are changed.
  expect(onDisk()).toContain('status: DONE')
  expect(onDisk()).not.toContain('updated: 2026-01-01T00:00:00+00:00')
  expect(onDisk()).toContain('Done by hand.')

  await undo.click()
  await expect(page.getByLabel('Properties')).toContainText('REVIEW')
  await expect(mark).toBeVisible()
  expect(onDisk()).toContain('status: REVIEW')
})

test('a note that is already done shows the check filled, and it cannot be pressed', async ({
  page,
}) => {
  writeFileSync(
    join(vault, 'tasks', 'p', 'Make the widget.md'),
    TASK.replace('status: REVIEW', 'status: DONE'),
  )
  await openNote(page, ['tasks', 'p'], 'Make the widget')
  await expect(page.getByRole('button', { name: 'Done' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Mark as done' })).toHaveCount(0)
})

test('a note that is not a task has no button for it', async ({ page }) => {
  await openNote(page, ['research'], 'Plain')
  await expect(page.getByRole('button', { name: 'Mark as done' })).toHaveCount(0)
})
