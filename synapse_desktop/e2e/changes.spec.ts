import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { expect, test, type Page } from './fixtures.ts'
import { launchCard, openLaunch, openSection, sidePanel, world } from './helpers.ts'

// A repository with one commit, which a terminal is started in.
function repository(): string {
  const dir = mkdtempSync(join(tmpdir(), 'sd-changes-'))
  const git = (...args: string[]) =>
    execFileSync('git', ['-c', 'user.name=A', '-c', 'user.email=a@example.com', ...args], {
      cwd: dir,
    })
  git('init', '-q')
  writeFileSync(join(dir, 'a.txt'), 'one\ntwo\nthree\n')
  git('add', '-A')
  git('commit', '-q', '-m', 'first')
  return dir
}

async function startShellIn(page: Page, folder: string) {
  await page.goto('/')
  await openLaunch(page)
  await page.getByLabel('Start in').fill(folder)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
  // The shell has run a command, so the session is up: the starting point of its changes is taken
  // before the program starts, and anything written from here on is a change.
  const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await terminal.click()
  await page.keyboard.type('echo up-$((40+2))')
  await page.keyboard.press('Enter')
  await expect(terminal).toContainText('up-42')
}

const toggle = (page: Page) => page.getByRole('button', { name: /^Show or hide the changes/ })
const sidebar = (page: Page) => page.getByRole('complementary', { name: 'Changes' })

test('the Changes sidebar is shut until it is opened, and shows what changed in the session folder', async ({
  page,
}) => {
  const dir = repository()
  try {
    await startShellIn(page, dir)
    await expect(sidebar(page)).toHaveCount(0)
    await expect(toggle(page)).toHaveAttribute('aria-pressed', 'false')

    writeFileSync(join(dir, 'a.txt'), 'one\nTWO\nthree\n')
    mkdirSync(join(dir, 'src'))
    writeFileSync(join(dir, 'src', 'new.txt'), 'hello\nworld\n')

    await toggle(page).click()
    await expect(sidebar(page)).toBeVisible()
    await expect(sidebar(page)).toContainText('2 files changed')

    // The first file that is not new is shown at once.
    const files = sidebar(page).getByRole('group', { name: 'Changed files' })
    await expect(files.getByRole('button', { name: /a\.txt/ })).toBeVisible()
    const diff = sidebar(page).getByRole('region', { name: 'Changes in a.txt' })
    await expect(diff).toContainText('TWO')
    await expect(diff.locator('.diff-row[data-kind="remove"]')).toContainText('two')
    await expect(diff.locator('.diff-row[data-kind="add"]')).toContainText('TWO')

    // A new file is a row under its folder, and its content is read when the row is opened.
    await expect(files).toContainText('src/')
    await expect(sidebar(page)).not.toContainText('hello')
    await files.getByRole('button', { name: /new\.txt/ }).click()
    const added = sidebar(page).getByRole('region', { name: 'Changes in src/new.txt' })
    await expect(added.locator('.diff-row[data-kind="add"]')).toHaveCount(2)
    await expect(added).toContainText('hello')

    // The count is on the icon, and the terminal still has every row and column it counts.
    await expect(toggle(page)).toContainText('2')
    // Measured where the terminal settles once it is fitted to its narrower box.
    const edges = () =>
      page.locator('.terminal-view:not([hidden]) .terminal-host').evaluate((host) => {
        const box = host.getBoundingClientRect()
        const text = host.querySelector('.xterm-screen')!.getBoundingClientRect()
        return Math.min(box.bottom - text.bottom, box.right - text.right)
      })
    await expect.poll(edges).toBeGreaterThanOrEqual(0)

    await toggle(page).click()
    await expect(sidebar(page)).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the sidebar says so when nothing has changed, and reads again when asked', async ({
  page,
}) => {
  const dir = repository()
  try {
    await startShellIn(page, dir)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')
    writeFileSync(join(dir, 'a.txt'), 'changed\n')
    await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
    await expect(sidebar(page)).toContainText('1 file changed')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

// Runs a command in the shell that is showing, and waits until it has run.
async function runInShell(page: Page, command: string, marker: string) {
  const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
  await terminal.click()
  await page.keyboard.type(`${command} && echo ${marker}-$((1+1))`)
  await page.keyboard.press('Enter')
  await expect(terminal).toContainText(`${marker}-2`)
}

test('a branch switch in the session starts a new comparison, and switching back restores the old one', async ({
  page,
}) => {
  // main has a.txt; other also has b.txt, committed, which a checkout writes and takes away.
  const dir = mkdtempSync(join(tmpdir(), 'sd-branches-'))
  const git = (...args: string[]) =>
    execFileSync('git', ['-c', 'user.name=A', '-c', 'user.email=a@example.com', ...args], {
      cwd: dir,
    })
  try {
    git('init', '-q', '-b', 'main')
    writeFileSync(join(dir, 'a.txt'), 'one\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'first')
    git('checkout', '-q', '-b', 'other')
    writeFileSync(join(dir, 'b.txt'), 'on other\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'second')
    git('checkout', '-q', 'main')

    await startShellIn(page, dir)
    await toggle(page).click()
    const again = sidebar(page).getByRole('button', { name: 'Read the changes again' })

    // A change on main.
    writeFileSync(join(dir, 'a.txt'), 'ONE\n')
    await again.click()
    await expect(sidebar(page)).toContainText('1 file changed')

    // On other the comparison starts again: b.txt, which the checkout wrote, is not a change.
    await runInShell(page, 'git checkout -q other', 'switched')
    await again.click()
    await expect(sidebar(page)).toContainText('Nothing has changed since switching to other.')
    writeFileSync(join(dir, 'c.txt'), 'new on other\n')
    await again.click()
    await expect(sidebar(page)).toContainText('1 file changed')
    await expect(
      sidebar(page).getByRole('button', { name: 'Since switching to other' }),
    ).toBeVisible()

    // Back on main, the snapshot it had: a.txt, and c.txt, which the checkout left in the folder.
    await runInShell(page, 'git checkout -q main', 'back')
    await again.click()
    await expect(
      sidebar(page).getByRole('button', { name: 'Since the session started on main' }),
    ).toBeVisible()
    await expect(sidebar(page)).toContainText('2 files changed')
    const files = sidebar(page).getByRole('group', { name: 'Changed files' })
    await expect(files.getByRole('button', { name: /a\.txt/ })).toBeVisible()
    await expect(files.getByRole('button', { name: /c\.txt/ })).toBeVisible()
    await expect(files.getByRole('button', { name: /b\.txt/ })).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

// A repository with the commits it is given, each a file written with its message as content.
function repositoryWith(messages: string[]): string {
  const dir = mkdtempSync(join(tmpdir(), 'sd-git-'))
  const git = (...args: string[]) =>
    execFileSync('git', ['-c', 'user.name=A', '-c', 'user.email=a@example.com', ...args], {
      cwd: dir,
    })
  git('init', '-q', '-b', 'main')
  messages.forEach((message, index) => {
    writeFileSync(join(dir, `f${index}.txt`), `${message}\n`)
    git('add', '-A')
    git('commit', '-q', '-m', message)
  })
  return dir
}

const gitTab = (page: Page) => sidebar(page).getByRole('tab', { name: 'Git' })
const commitList = (page: Page) => sidebar(page).getByRole('group', { name: 'Commits' })

test('the Git tab lists the commits of the session newest first, and shows what one changed', async ({
  page,
}) => {
  const dir = repositoryWith(['first', 'second', 'third'])
  try {
    await startShellIn(page, dir)
    await toggle(page).click()
    await gitTab(page).click()
    await expect(gitTab(page)).toHaveAttribute('aria-selected', 'true')
    const rows = commitList(page).getByRole('button')
    await expect(rows).toHaveCount(3)
    await expect(rows.nth(0)).toContainText('third')
    // Each commit added one line, which its row says on the right.
    await expect(rows.nth(0).locator('.changes-added')).toHaveText('+1')
    await expect(rows.nth(2)).toContainText('first')

    // A commit: its heading, its file, and its diff.
    await rows.nth(1).click()
    await expect(sidebar(page)).toContainText('second')
    const files = sidebar(page).getByRole('group', { name: 'Changed files' })
    await files.getByRole('button', { name: /f1\.txt/ }).click()
    const diff = sidebar(page).getByRole('region', { name: 'Changes in f1.txt' })
    await expect(diff.locator('.diff-row[data-kind="add"]')).toContainText('second')

    // Back to the list, and a commit made in the shell is there when the tab is shown again.
    await sidebar(page).getByRole('button', { name: '← Commits' }).click()
    await expect(commitList(page)).toBeVisible()
    await runInShell(
      page,
      'echo four > f3.txt && git add -A && git -c user.name=A -c user.email=a@example.com commit -q -m fourth',
      'committed',
    )
    await sidebar(page).getByRole('tab', { name: 'Changes' }).click()
    await gitTab(page).click()
    await expect(commitList(page).getByRole('button').nth(0)).toContainText('fourth')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the Git tab shows fifty commits at a time, and the rest when asked', async ({ page }) => {
  const dir = repositoryWith(Array.from({ length: 55 }, (_, i) => `commit ${i + 1}`))
  try {
    await startShellIn(page, dir)
    await toggle(page).click()
    await gitTab(page).click()
    const rows = commitList(page).locator('.git-commit')
    await expect(rows).toHaveCount(50)
    await commitList(page).getByRole('button', { name: 'Load more' }).click()
    await expect(rows).toHaveCount(55)
    await expect(rows.nth(54)).toContainText('commit 1')
    await expect(commitList(page).getByRole('button', { name: 'Load more' })).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a folder that is not in a repository has no diff to show, and the sidebar says it', async ({
  page,
}) => {
  const dir = mkdtempSync(join(tmpdir(), 'sd-plain-'))
  try {
    await startShellIn(page, dir)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('not in a git repository')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('on a page that is not a terminal the sidebar says changes are shown for a session', async ({
  page,
}) => {
  await page.goto('/')
  await toggle(page).click()
  await expect(sidebar(page)).toContainText('Changes are shown for a terminal session')
})

test("a run's changes are everything it changed in its folder, and a repository can be added to them", async ({
  page,
}) => {
  const other = repository()
  try {
    // Changed before it is added: the run's start in it is its last commit.
    writeFileSync(join(other, 'a.txt'), 'one\nchanged before\nthree\n')

    await page.goto('/')
    await openSection(page, 'Executions')
    await sidePanel(page)
      .getByRole('button', { name: /exec-fixture1/ })
      .click()
    await expect(page.getByRole('heading', { level: 1, name: 'exec-fixture1' })).toBeVisible()
    await expect(sidebar(page)).toHaveCount(0)

    // The Trace's link opens the changes of the whole run, from its start to its end.
    await page.getByRole('button', { name: 'Changes', exact: true }).click()
    await expect(sidebar(page)).toContainText('3 files changed')
    await expect(toggle(page)).toContainText('3')
    // A run has its changes only: there is no Git tab, no step to choose, and its lines cannot be
    // chosen for a review, since it has no terminal to send one to.
    await expect(sidebar(page).getByRole('tab')).toHaveCount(0)
    await expect(sidebar(page).getByRole('group', { name: 'Compared with' })).toHaveCount(0)
    await expect(sidebar(page).locator('.diff-pick')).toHaveCount(0)
    await expect(reviewBar(page)).toHaveCount(0)
    // Its folder is shown, and cannot be changed.
    await expect(sidebar(page)).toContainText(world().project)
    await expect(sidebar(page).getByRole('button', { name: /^Folder: / })).toHaveCount(0)

    // A file that existed is shown at once; a new file is a row to open.
    const files = sidebar(page).getByRole('group', { name: 'Changed files' })
    const diff = sidebar(page).getByRole('region', { name: 'Changes in src/render.adb' })
    await expect(diff.locator('.diff-row[data-kind="remove"]')).toContainText('False')
    await expect(diff.locator('.diff-row[data-kind="add"]')).toContainText('True')
    await expect(sidebar(page)).not.toContainText('written by the step')
    await files.getByRole('button', { name: /fresh\.adb/ }).click()
    await expect(
      sidebar(page).getByRole('region', { name: 'Changes in src/fresh.adb' }),
    ).toContainText('written by the step')

    // Another repository is added with the +: each is a group headed by its folder's name.
    await sidebar(page).getByRole('button', { name: 'Add a repository' }).click()
    const input = sidebar(page).getByLabel('Repository to add')
    await input.fill(other)
    await input.press('Enter')
    const own = sidebar(page).getByRole('region', { name: 'project', exact: true })
    const added = sidebar(page).getByRole('region', { name: basename(other), exact: true })
    await expect(own.getByRole('button', { name: /project/ }).first()).toContainText('3 files')
    await expect(
      added.getByRole('button', { name: new RegExp(basename(other)) }).first(),
    ).toContainText('1 file')
    await expect(added).toContainText('changed before')
    await expect(toggle(page)).toContainText('4')

    // The run is over, so what is changed in the added repository from now on is not its change.
    writeFileSync(join(other, 'later.txt'), 'after the end\n')
    await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
    await expect(
      added.getByRole('button', { name: new RegExp(basename(other)) }).first(),
    ).toContainText('1 file')
    await expect(added).not.toContainText('later.txt')
  } finally {
    rmSync(other, { recursive: true, force: true })
  }
})

test('a file an activity says was changed opens its diff in the sidebar, and a folder can be shut', async ({
  page,
}) => {
  await page.goto('/')
  await openSection(page, 'Executions')
  await sidePanel(page)
    .getByRole('button', { name: /exec-fixture1/ })
    .click()
  await page.getByRole('button', { name: 'Activity' }).click()
  await expect(sidebar(page)).toHaveCount(0)

  // The file in the activity is the file of the patch, though one has its whole path.
  await page
    .getByLabel('Files changed')
    .getByRole('button', { name: /result\.txt/ })
    .click()
  await expect(sidebar(page)).toBeVisible()
  await expect(sidebar(page).getByRole('region', { name: 'Changes in result.txt' })).toContainText(
    'pineapple',
  )

  // A folder of the list is shut and opened again.
  const files = sidebar(page).getByRole('group', { name: 'Changed files' })
  const folder = files.getByRole('button', { name: /^.? ?src\/$/ })
  await expect(files.getByRole('button', { name: /render\.adb/ })).toBeVisible()
  await folder.click()
  await expect(files.getByRole('button', { name: /render\.adb/ })).toHaveCount(0)
  await expect(folder).toHaveAttribute('aria-expanded', 'false')
  await folder.click()
  await expect(files.getByRole('button', { name: /render\.adb/ })).toBeVisible()
})

test('a claude started in the shell, in a repository the shell did not start in, has its changes shown', async ({
  page,
}) => {
  const repo = repository()
  const plain = mkdtempSync(join(tmpdir(), 'sd-plain-'))
  try {
    await startShellIn(page, plain)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('not in a git repository')

    // The conversation of the claude is where its changes are, whatever folder the shell began in.
    const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
    await terminal.click()
    await page.keyboard.type(`cd '${repo}' && claude fix it`)
    await page.keyboard.press('Enter')
    // The claude's conversation is followed: the Activity tab has it.
    await sidebar(page).getByRole('tab', { name: 'Activity' }).click()
    await expect(sidebar(page).locator('.activity-row').first()).toBeVisible()
    await sidebar(page).getByRole('tab', { name: 'Changes' }).click()
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')

    writeFileSync(join(repo, 'a.txt'), 'one\nchanged by claude\nthree\n')
    await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
    await expect(sidebar(page)).toContainText('1 file changed')
    await expect(sidebar(page).getByRole('region', { name: 'Changes in a.txt' })).toContainText(
      'changed by claude',
    )
  } finally {
    rmSync(repo, { recursive: true, force: true })
    rmSync(plain, { recursive: true, force: true })
  }
})

for (const harness of ['claude', 'codex', 'opencode']) {
  test(`a ${harness} started in a shell that was started elsewhere shows the Changes and Git tabs of its own folder`, async ({
    page,
  }) => {
    const repo = repository()
    const plain = mkdtempSync(join(tmpdir(), 'sd-plain-'))
    try {
      await startShellIn(page, plain)
      await toggle(page).click()
      await expect(sidebar(page)).toContainText('not in a git repository')

      const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
      await terminal.click()
      // OpenCode takes a folder or a command as its first word, so it is started with none.
      const started = harness === 'opencode' ? harness : `${harness} fix it`
      await page.keyboard.type(`cd '${repo}' && ${started}`)
      await page.keyboard.press('Enter')
      await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')
      await expect(sidebar(page)).not.toContainText('not in a git repository')

      writeFileSync(join(repo, 'a.txt'), `one\nchanged by ${harness}\nthree\n`)
      await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
      await expect(sidebar(page)).toContainText('1 file changed')
      await expect(sidebar(page).getByRole('region', { name: 'Changes in a.txt' })).toContainText(
        `changed by ${harness}`,
      )

      await gitTab(page).click()
      await expect(commitList(page).getByRole('button').nth(0)).toContainText('first')
    } finally {
      rmSync(repo, { recursive: true, force: true })
      rmSync(plain, { recursive: true, force: true })
    }
  })
}

// Chooses lines 2 and 3 of a.txt's diff, from the changed line to the one after it, and comments.
async function commentOnLines(page: Page, text: string) {
  const diff = sidebar(page).getByRole('region', { name: 'Changes in a.txt' })
  await diff
    .locator('.diff-row[data-kind="add"]')
    .getByRole('button', { name: 'Choose line 2' })
    .click()
  await diff.getByRole('button', { name: 'Choose line 3' }).click({ modifiers: ['Shift'] })
  const box = diff.getByRole('group', { name: 'Comment on the chosen lines' })
  await expect(box).toContainText('Lines 2–3 chosen')
  // Directly under the last chosen line, where the person is looking, not at the end of the hunk.
  await expect(
    diff.locator(
      '.diff-row[data-chosen="true"] + [role="group"][aria-label="Comment on the chosen lines"]',
    ),
  ).toHaveCount(1)
  // Typed as typed: macOS does not capitalize or correct in the app's fields.
  await expect(box.getByRole('textbox', { name: 'Comment' })).toHaveAttribute(
    'autocapitalize',
    'off',
  )
  await expect(box.getByRole('textbox', { name: 'Comment' })).toHaveAttribute('autocorrect', 'off')
  await box.getByRole('textbox', { name: 'Comment' }).fill(text)
  await box.getByRole('button', { name: 'Save' }).click()
  await expect(box).toHaveCount(0)
}

const reviewBar = (page: Page) => sidebar(page).getByRole('region', { name: 'Review' })

test('lines of a diff are commented on, and a review where no harness runs can be copied, not sent', async ({
  page,
}) => {
  const dir = repository()
  try {
    await startShellIn(page, dir)
    writeFileSync(join(dir, 'a.txt'), 'one\nTWO\nthree\n')
    await toggle(page).click()
    await commentOnLines(page, 'Use lower case.')

    await expect(reviewBar(page)).toContainText('1 comment')
    await expect(reviewBar(page).getByRole('button', { name: 'Copy' })).toBeVisible()
    await expect(reviewBar(page).getByRole('button', { name: 'Send to agent' })).toHaveCount(0)
    await expect(reviewBar(page)).toContainText('No harness runs in this session')
    await expect(sidebar(page).locator('.diff-row[data-commented="true"]')).toHaveCount(2)

    // The list of the review: a comment's place and text, edited, then removed.
    await reviewBar(page).getByRole('button', { name: '1 comment' }).click()
    await expect(reviewBar(page)).toContainText('a.txt:2-3')
    await reviewBar(page).getByRole('button', { name: 'Edit' }).click()
    await reviewBar(page).getByRole('textbox', { name: 'Comment' }).fill('Lower case, please.')
    await reviewBar(page).getByRole('button', { name: 'Save' }).click()
    await expect(reviewBar(page)).toContainText('Lower case, please.')
    await reviewBar(page).getByRole('button', { name: 'Remove' }).click()
    await expect(reviewBar(page)).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a review is pasted into a shell in which a harness was started, for the person to submit', async ({
  page,
}) => {
  const dir = repository()
  const plain = mkdtempSync(join(tmpdir(), 'sd-plain-'))
  try {
    // The shell starts where there is no repository, so that the session's starting point is
    // there only once the claude's conversation is found and its folder is snapshotted.
    await startShellIn(page, plain)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('not in a git repository')
    const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
    await terminal.click()
    await page.keyboard.type(`cd '${dir}' && claude fix it`)
    await page.keyboard.press('Enter')
    // The claude's conversation is followed: the Activity tab has it.
    await sidebar(page).getByRole('tab', { name: 'Activity' }).click()
    await expect(sidebar(page).locator('.activity-row').first()).toBeVisible()
    await sidebar(page).getByRole('tab', { name: 'Changes' }).click()
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')

    writeFileSync(join(dir, 'a.txt'), 'one\nTWO\nthree\n')
    await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
    await commentOnLines(page, 'Use lower case.')

    // In a shell the harness started in may have ended, so the review is pasted, not submitted:
    // the person presses Enter.
    await reviewBar(page).getByRole('button', { name: 'Send to agent' }).click()
    await expect(terminal).toContainText('Review of your changes')
    await expect(terminal).toContainText('a.txt:2-3')
    await expect(reviewBar(page)).toContainText('press Enter there to send it')
    await expect(reviewBar(page).getByRole('button', { name: 'Send to agent' })).toHaveCount(0)
  } finally {
    rmSync(dir, { recursive: true, force: true })
    rmSync(plain, { recursive: true, force: true })
  }
})

test('a file in the Activity tab shows what the conversation did to it, and its diff since the session started', async ({
  page,
}) => {
  const dir = repository()
  const plain = mkdtempSync(join(tmpdir(), 'sd-plain-'))
  try {
    await startShellIn(page, plain)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('not in a git repository')
    const terminal = page.locator('.terminal-view:not([hidden]) .terminal-host')
    await terminal.click()
    // The claude edits a.txt; what it wrote is put in the file once its folder is the starting point.
    await page.keyboard.type(`cd '${dir}' && claude edit it`)
    await page.keyboard.press('Enter')
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')
    writeFileSync(join(dir, 'a.txt'), 'one\nTWO\nthree\n')
    // Compared with the last commit, as a person may have left it.
    await sidebar(page).getByRole('button', { name: 'Not committed' }).click()

    // The file's name shows only what was done to it, opened.
    await sidebar(page).getByRole('tab', { name: 'Activity' }).click()
    const files = sidebar(page).getByRole('region', { name: 'Files changed' })
    await files.getByRole('button', { name: /a\.txt/ }).click()
    await expect(
      sidebar(page).getByRole('button', { name: 'Show every file, not only a.txt' }),
    ).toBeVisible()
    const rows = sidebar(page).locator('.activity-row')
    await expect(rows).toHaveCount(1)
    await expect(rows.nth(0)).toContainText('TWO')

    // Its diff is in the Changes tab, compared with where the session started.
    await files.getByRole('button', { name: 'Diff' }).click()
    await expect(sidebar(page).getByRole('tab', { name: 'Changes' })).toHaveAttribute(
      'aria-selected',
      'true',
    )
    await expect(
      sidebar(page).getByRole('button', { name: 'Since the session started' }),
    ).toHaveAttribute('aria-pressed', 'true')
    await expect(sidebar(page).getByRole('region', { name: 'Changes in a.txt' })).toContainText(
      'TWO',
    )

    // Back in the Activity tab the file is still chosen, and the chip lets go of it.
    await sidebar(page).getByRole('tab', { name: 'Activity' }).click()
    await expect(rows).toHaveCount(1)
    await sidebar(page).getByRole('button', { name: 'Show every file, not only a.txt' }).click()
    await expect(rows).toHaveCount(4)
  } finally {
    rmSync(dir, { recursive: true, force: true })
    rmSync(plain, { recursive: true, force: true })
  }
})

test('what is not committed can be shown, whatever was changed before the session started', async ({
  page,
}) => {
  const dir = repository()
  // Changed before the session, and not committed.
  writeFileSync(join(dir, 'a.txt'), 'one\nchanged before\nthree\n')
  try {
    await startShellIn(page, dir)
    await toggle(page).click()
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')
    const compared = sidebar(page).getByRole('group', { name: 'Compared with' })
    await expect(
      compared.getByRole('button', { name: 'Since the session started' }),
    ).toHaveAttribute('aria-pressed', 'true')

    await compared.getByRole('button', { name: 'Not committed' }).click()
    await expect(sidebar(page)).toContainText('1 file changed')
    await expect(sidebar(page).getByRole('region', { name: 'Changes in a.txt' })).toContainText(
      'changed before',
    )

    await compared.getByRole('button', { name: 'Since the session started' }).click()
    await expect(sidebar(page)).toContainText('Nothing has changed since this session started.')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the folder of the Changes sidebar is moved by typing the path of another one', async ({
  page,
}) => {
  const first = repository()
  const second = repository()
  const plain = mkdtempSync(join(tmpdir(), 'sd-plain-'))
  try {
    await startShellIn(page, first)
    await toggle(page).click()
    const folder = sidebar(page).getByRole('button', { name: /^Folder: .* Change it$/ })
    await expect(folder).toContainText(first)

    // A folder that is not in a repository is refused, and the sidebar stays where it was.
    await folder.click()
    const input = sidebar(page).getByLabel('Folder to look at')
    await input.fill(plain)
    await input.press('Enter')
    await expect(sidebar(page).getByRole('alert')).toContainText('not in a git repository')
    await input.press('Escape')
    await expect(folder).toContainText(first)

    // The changes of the folder moved to are the ones shown, from the moment it is moved to.
    await folder.click()
    await input.fill(second)
    await input.press('Enter')
    await expect(folder).toContainText(second)
    writeFileSync(join(second, 'moved.txt'), 'here\n')
    await expect(sidebar(page)).toContainText('1 file changed')
    await expect(sidebar(page)).toContainText('moved.txt')

    // Going back restores the folder that was left.
    writeFileSync(join(first, 'first-only.txt'), 'there\n')
    await folder.click()
    await input.fill(first)
    await input.press('Enter')
    await expect(folder).toContainText(first)
    await expect(sidebar(page)).toContainText('first-only.txt')
    await expect(sidebar(page)).not.toContainText('moved.txt')
  } finally {
    rmSync(first, { recursive: true, force: true })
    rmSync(second, { recursive: true, force: true })
    rmSync(plain, { recursive: true, force: true })
  }
})

test('in a terminal session a second repository is added with the +, and a comment in it names it', async ({
  page,
}) => {
  const first = repository()
  const second = repository()
  try {
    await startShellIn(page, first)
    await toggle(page).click()
    await sidebar(page).getByRole('button', { name: 'Add a repository' }).click()
    const input = sidebar(page).getByLabel('Repository to add')
    await input.fill(second)
    await input.press('Enter')
    await expect(sidebar(page).getByRole('list', { name: 'Repositories added' })).toContainText(
      basename(second),
    )

    // What changes in each from now on is a group of its own, headed by its folder's name.
    writeFileSync(join(first, 'b.txt'), 'new in the first\n')
    writeFileSync(join(second, 'a.txt'), 'one\nTWO\nthree\n')
    await sidebar(page).getByRole('button', { name: 'Read the changes again' }).click()
    const own = sidebar(page).getByRole('region', { name: basename(first), exact: true })
    const added = sidebar(page).getByRole('region', { name: basename(second), exact: true })
    await expect(own).toContainText('b.txt')
    await expect(
      added.getByRole('button', { name: new RegExp(basename(second)) }).first(),
    ).toContainText('1 file')

    // A comment on the added repository's file says which repository it is in.
    await commentOnLines(page, 'Use lower case.')
    await reviewBar(page).getByRole('button', { name: '1 comment' }).click()
    await expect(reviewBar(page)).toContainText(`${basename(second)}/a.txt:2-3`)
  } finally {
    rmSync(first, { recursive: true, force: true })
    rmSync(second, { recursive: true, force: true })
  }
})
