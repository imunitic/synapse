import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, type Page } from './fixtures.ts'
import { launchCard, openLaunch, openSection, world } from './helpers.ts'

const injected = () => join(world().data, 'synapse-desktop', 'injected')

// The terminal of the tab that is showing.
const screen = (page: Page) => page.locator('.terminal-view:not([hidden]) .terminal-host')

async function openTerminals(page: Page, folder = '') {
  await page.goto('/')
  await openLaunch(page)
  await page.getByLabel('Start in').fill(folder)
}

// A harness started in a folder it has not worked in, typed into its card.
async function startHarness(page: Page, name: 'Claude Code', folder: string) {
  await page.goto('/')
  await openLaunch(page)
  const card = launchCard(page, name)
  await card.getByLabel('Another folder').fill(folder)
  await card.getByRole('button', { name: 'Start' }).click()
}

const sidebar = (page: Page) => page.getByRole('complementary', { name: 'Changes' })

// The Activity tab of the Changes sidebar, where a session's followed conversation is shown.
async function showConversation(page: Page) {
  const toggle = page.getByRole('button', { name: /^Show or hide the changes/ })
  if ((await toggle.getAttribute('aria-pressed')) !== 'true') await toggle.click()
  await sidebar(page).getByRole('tab', { name: 'Activity' }).click()
  return sidebar(page)
}

async function type(page: Page, text: string) {
  await screen(page).click()
  await page.keyboard.type(text)
  await page.keyboard.press('Enter')
}

test('a new shell starts in the home folder and runs what is typed', async ({ page }) => {
  await openTerminals(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()

  // The sum is done by the shell: its result is not in the line that was typed.
  await type(page, 'echo sum-$((40+2)) home=$HOME')
  await expect(screen(page)).toContainText(`sum-42 home=${world().home}`)
  await type(page, 'pwd')
  await expect(screen(page)).toContainText(world().home)
})

test('claude typed in the shell starts with Synapse loaded for that run only', async ({ page }) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.locator('.terminal-note')).toHaveCount(0)

  // The wrapper is the claude of this shell; nothing runs until it is.
  const wrapper = join(injected(), 'shims', 'claude')
  await type(page, 'echo which=$(command -v claude)')
  await expect(screen(page)).toContainText(`which=${wrapper}`)

  await type(page, 'claude one two')
  await expect(screen(page)).toContainText('STUB claude args: --add-dir')
  await expect(screen(page)).toContainText('one two')
  await expect(screen(page)).toContainText(join(injected(), 'claude', 'overlay'))
  // Nothing was installed in the home: no skills and no commands of Synapse.
  expect(existsSync(join(world().home, '.claude', 'skills'))).toBe(false)
  expect(existsSync(join(world().home, '.claude', 'commands'))).toBe(false)
  expect(
    existsSync(
      join(injected(), 'claude', 'overlay', '.claude', 'skills', 'synapse-query', 'SKILL.md'),
    ),
  ).toBe(true)
})

test('codex and opencode typed in the shell get their homes of their own', async ({ page }) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'codex')
  await expect(screen(page)).toContainText(`CODEX_HOME=${join(injected(), 'codex')}`)
  await type(page, 'quit')
  await type(page, 'opencode')
  await expect(screen(page)).toContainText(`OPENCODE_CONFIG_DIR=${join(injected(), 'opencode')}`)
})

test('a harness that has Synapse installed gets nothing loaded, and is still followed', async ({
  page,
}) => {
  mkdirSync(join(world().home, '.claude'), { recursive: true })
  writeFileSync(
    join(world().home, '.claude', 'settings.json'),
    '{"hooks":{"SessionStart":[{"hooks":[{"command":"/x/synapse-hook start"}]}]}}',
  )
  try {
    await openTerminals(page, world().root)
    await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
    await expect(page.locator('.terminal-note')).toHaveCount(0)
    await type(page, 'claude hello')
    await expect(screen(page)).toContainText('STUB claude args: --session-id')
    await expect(screen(page)).not.toContainText('--add-dir')
    await expect(await showConversation(page)).toContainText('Fix the bug in a.txt')
  } finally {
    rmSync(join(world().home, '.claude'), { recursive: true, force: true })
  }
})

test('the conversation of a claude started in the shell shows in the Activity tab, in full', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  const activity = await showConversation(page)
  await expect(activity).toContainText('No harness conversation is followed in this session.')
  await type(page, 'claude fix it')

  const rows = activity.locator('.activity-row')
  await expect(rows).toHaveCount(3)
  await expect(rows.nth(0)).toContainText('you')
  await expect(rows.nth(0)).toContainText('Fix the bug in a.txt')
  await expect(rows.nth(1)).toContainText('I will look at the folder.')
  await expect(rows.nth(2).locator('.activity-target')).toHaveText('ls -la')
  // The output of a tool call is there to open, or all at once.
  await expect(activity.getByText('total 8 a.txt')).toBeHidden()
  await activity.getByRole('button', { name: 'Expand all' }).click()
  await expect(activity.getByText('total 8 a.txt')).toBeVisible()
  await activity.getByRole('button', { name: 'Collapse all' }).click()
  await expect(activity.getByText('total 8 a.txt')).toBeHidden()
  // It is not under the terminal any more.
  await expect(page.getByLabel('Conversation')).toHaveCount(0)
})

test('the Activity tab shows the kinds of action chosen, and keeps them for the session', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'claude fix it')
  const activity = await showConversation(page)
  const rows = activity.locator('.activity-row')
  await expect(rows).toHaveCount(3)
  const kinds = activity.getByRole('group', { name: 'Kinds of action shown' })
  await expect(kinds.getByRole('button')).toHaveText(['Prompts 1', 'Messages 1', 'Commands 1'])
  // Above the list, not in it: a long conversation scrolls, and the chips stay in view.
  await expect(
    activity.getByLabel('Activity').getByRole('group', { name: 'Kinds of action shown' }),
  ).toHaveCount(0)

  await kinds.getByRole('button', { name: 'Commands 1' }).click()
  await expect(rows).toHaveCount(1)
  await expect(rows.nth(0).locator('.activity-target')).toHaveText('ls -la')
  await kinds.getByRole('button', { name: 'Prompts 1' }).click()
  await expect(rows).toHaveCount(2)

  // Kept while another tab is shown.
  await activity.getByRole('tab', { name: 'Changes' }).click()
  await activity.getByRole('tab', { name: 'Activity' }).click()
  await expect(rows).toHaveCount(2)
  await expect(kinds.getByRole('button', { name: 'Commands 1' })).toHaveAttribute(
    'aria-pressed',
    'true',
  )

  // None chosen is all of them.
  await kinds.getByRole('button', { name: 'Commands 1' }).click()
  await kinds.getByRole('button', { name: 'Prompts 1' }).click()
  await expect(rows).toHaveCount(3)
})

test('a claude started in a tab of its own has its conversation followed', async ({ page }) => {
  await startHarness(page, 'Claude Code', world().root)
  const conversation = await showConversation(page)
  await expect(conversation).toContainText('Fix the bug in a.txt')
  await expect(conversation.locator('.activity-row')).toHaveCount(3)
})

test('a codex started in the shell has its conversation followed', async ({ page }) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'codex')
  const conversation = await showConversation(page)
  await expect(conversation).toContainText('Add a test')
  await expect(conversation).toContainText('echo hello-codex')
  await expect(conversation).toContainText('Added it.')
  await expect(conversation.locator('.activity-row')).toHaveCount(3)
})

test('a run that resumes a session by its id follows that session, and its arguments are untouched', async ({
  page,
}) => {
  const id = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'
  const project = join(world().home, '.claude', 'projects', '-elsewhere')
  mkdirSync(project, { recursive: true })
  writeFileSync(
    join(project, `${id}.jsonl`),
    '{"type":"user","message":{"role":"user","content":"Earlier work"}}\n',
  )
  try {
    await openTerminals(page, world().root)
    await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
    await type(page, `claude --resume ${id}`)
    await expect(screen(page)).toContainText(`--resume ${id}`)
    await expect(screen(page)).not.toContainText('--session-id')
    const conversation = await showConversation(page)
    await expect(conversation).toContainText('Earlier work')
    await expect(conversation).toContainText('Carry on')
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
})

test('a harness can be started directly in a tab of its own', async ({ page }) => {
  await startHarness(page, 'Claude Code', world().root)
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toBeVisible()
  await expect(page.locator('.terminal-note')).toHaveCount(0)
  await expect(screen(page)).toContainText('STUB claude args: --add-dir')
  await expect(screen(page)).toContainText(`cwd: ${world().root}`)

  await type(page, 'hello')
  await expect(screen(page)).toContainText('typed: hello')
  await type(page, 'quit')
  await expect(screen(page)).toContainText('the program ended with code 7')
  await expect(page.getByText('The session ended.')).toBeVisible()
  await page.getByRole('button', { name: 'Close the tab' }).click()
  await expect(page.getByRole('tab', { name: 'Claude Code 1' })).toHaveCount(0)
})

test('shells have tabs: each goes on while the others show, and closing one leaves the rest', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'MARK=first; echo tab-$MARK')
  await expect(screen(page)).toContainText('tab-first')

  await page.getByRole('button', { name: 'New shell', exact: true }).first().click()
  await expect(page.getByRole('tab', { name: 'Shell 2' })).toBeVisible()
  // A shell of its own: the variable of the first one is not in it.
  await type(page, 'echo second-${MARK:-none}')
  await expect(screen(page)).toContainText('second-none')

  await page.getByRole('tab', { name: 'Shell 1' }).click()
  await type(page, 'echo again-$MARK')
  await expect(screen(page)).toContainText('again-first')

  await page.getByRole('button', { name: 'Close Shell 1' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toHaveCount(0)
  await expect(page.getByRole('tab', { name: 'Shell 2' })).toHaveAttribute('aria-selected', 'true')
})

test('shell tabs are put in another order by dragging, or with Alt and the arrow keys', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await page.getByRole('button', { name: 'New shell', exact: true }).first().click()
  await page.getByRole('button', { name: 'New shell', exact: true }).first().click()
  const names = () =>
    page
      .getByRole('tablist', { name: 'Terminal tabs' })
      .getByRole('tab')
      .allInnerTexts()
      .then((texts) => texts.map((t) => t.trim()))
  await expect.poll(names).toEqual(['Shell 1', 'Shell 2', 'Shell 3'])

  await page
    .getByRole('tab', { name: 'Shell 3' })
    .dragTo(page.getByRole('tab', { name: 'Shell 1' }), { targetPosition: { x: 2, y: 10 } })
  await expect.poll(names).toEqual(['Shell 3', 'Shell 1', 'Shell 2'])
  // The tab that was selected is still the one showing.
  await expect(page.getByRole('tab', { name: 'Shell 3' })).toHaveAttribute('aria-selected', 'true')

  await page.getByRole('tab', { name: 'Shell 3' }).focus()
  await page.keyboard.press('Alt+ArrowRight')
  await expect.poll(names).toEqual(['Shell 1', 'Shell 3', 'Shell 2'])
})

test('sessions go on while another page of the app shows', async ({ page }) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'MARK=kept')

  await openSection(page, 'Settings')
  await page.locator('.settings-item').filter({ hasText: 'General' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'General' })).toBeVisible()
  await expect(page.locator('.terminal-host')).toBeHidden()

  await page.getByRole('tab', { name: 'Terminals' }).click()
  await type(page, 'echo back-$MARK')
  await expect(screen(page)).toContainText('back-kept')
})

test('a folder that is not one is said in the tab', async ({ page }) => {
  await openTerminals(page, join(world().root, 'nowhere'))
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(screen(page)).toContainText('is not a folder')
  await expect(page.getByText('The session ended.')).toBeVisible()
})

test('a reload attaches to the same session and shows its screen, and closing the tab ends it', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await type(page, 'MARK=held; echo before-$MARK')
  await expect(screen(page)).toContainText('before-held')

  await page.reload()
  // The page has none of its state: the host still has the session, and the page attaches to it.
  await page.getByRole('tab', { name: 'Terminals' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  // What was on the screen comes back, and so does the shell that drew it, with its variable.
  await expect(screen(page)).toContainText('before-held')
  await type(page, 'echo after-$MARK')
  await expect(screen(page)).toContainText('after-held')

  // Closing the tab ends the session: after another reload there is none to attach to.
  await page.getByRole('button', { name: 'Close Shell 1' }).click()
  await page.reload()
  await page.waitForTimeout(500)
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toHaveCount(0)
})

test('a terminal tab is named by double-clicking it, and keeps the name after a reload', async ({
  page,
}) => {
  await openTerminals(page, world().root)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()

  // Escape keeps the name it had.
  await page.getByRole('tab', { name: 'Shell 1' }).dblclick()
  await page.getByLabel('New name for Shell 1').fill('ignored')
  await page.keyboard.press('Escape')
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()

  await page.getByRole('tab', { name: 'Shell 1' }).dblclick()
  await page.getByLabel('New name for Shell 1').fill('build')
  await page.keyboard.press('Enter')
  await expect(page.getByRole('tab', { name: 'build' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Close build' })).toBeVisible()

  await page.reload()
  await page.getByRole('tab', { name: 'Terminals' }).click()
  await expect(page.getByRole('tab', { name: 'build' })).toBeVisible()

  // A blank name gives it back its title.
  await page.getByRole('tab', { name: 'build' }).dblclick()
  await page.getByLabel('New name for build').fill('')
  await page.keyboard.press('Enter')
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  await page.getByRole('button', { name: 'Close Shell 1' }).click()
})

test.describe('in a wide window', () => {
  test.use({ viewport: { width: 1900, height: 900 } })

  test('the terminal takes the width of the page, not the width of the cards', async ({ page }) => {
    await openTerminals(page)
    await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
    await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
    const width = (selector: string) =>
      page.locator(selector).evaluate((element) => element.getBoundingClientRect().width)
    const content = await page
      .locator('.terminals-page')
      .evaluate((element) => element.getBoundingClientRect().width)
    // 62.5rem, the width of the cards, is 1125px at the default text size.
    expect(content).toBeGreaterThan(1125)
    expect(await width('.terminal-view:not([hidden])')).toBe(content)
  })
})

test('the terminal shows every row and column it has: none is cut off by its box', async ({
  page,
}) => {
  await openTerminals(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  await expect(screen(page).locator('.xterm-screen')).toBeVisible()

  // The rows and columns are counted from the box, and what they take must fit inside it. The
  // terminal is fitted to its box once the box has a size, after it first draws its default 24
  // rows: what is measured is where it settles.
  const edges = () =>
    screen(page).evaluate((host) => {
      const box = host.getBoundingClientRect()
      const text = host.querySelector('.xterm-screen')!.getBoundingClientRect()
      return Math.min(box.bottom - text.bottom, box.right - text.right)
    })
  await expect.poll(edges).toBeGreaterThanOrEqual(0)
})

test('the terminal draws no scrollbar of the browser at its edge, only its own', async ({
  page,
}) => {
  await openTerminals(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(screen(page).locator('.xterm-screen')).toBeVisible()
  // xterm.css makes its viewport scroll, which xterm 6 does not use, and a webview with classic
  // scrollbars draws an empty track down the right edge. Headless Chromium hides scrollbars, so
  // the style is what is looked at.
  const viewport = screen(page).locator('.xterm-viewport')
  await expect(viewport).toHaveCSS('overflow-y', 'hidden')
  // Scrolling still works, through xterm's own scrollbar.
  await expect(screen(page).locator('.xterm-scrollable-element')).toHaveCount(1)
})

test('an interactive run has no tab on the Terminals page, and brings no Terminals page', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await page
    .getByLabel('Side panel')
    .getByRole('button', { name: /Fixture_Run/ })
    .click()
  await page.getByRole('button', { name: 'Run', exact: true }).click()
  const dialog = page.getByRole('dialog')
  // The dialog starts an interactive run, without the box touched.
  await dialog.getByLabel(/Folder its agents work in/).fill(world().root)
  await dialog.getByRole('button', { name: 'Start run' }).click()
  // The run is shown on its own page; no page of terminals opens for it, and it has no tab there.
  await expect(page.getByRole('tab', { name: 'Terminals' })).toHaveCount(0)
  await expect(page.getByRole('tablist', { name: 'Terminal tabs' })).toHaveCount(0)
  // Opening the Terminals page lists a new shell only.
  await openLaunch(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  // The run counted as one opened, so the shell is not "Shell 1".
  await expect(page.getByRole('tab', { name: /^Shell \d/ })).toBeVisible()
  await expect(page.getByRole('tablist', { name: 'Terminal tabs' }).getByRole('tab')).toHaveCount(1)
})
