import { readFileSync, writeFileSync } from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import { launchCard, openLaunch, openSection, world } from './helpers.ts'

const bar = (page: Page) => page.getByRole('tablist', { name: 'Open pages' })
const order = async (page: Page) => bar(page).getByRole('tab').allInnerTexts()
// The whole tab, which is what is dragged and middle-clicked, not only its label.
const tab = (page: Page, name: string) =>
  page.locator('.tabbar .tab').filter({ has: page.getByRole('tab', { name, exact: true }) })

// A point near the right edge of a tab, which is its right half however wide the tab is.
async function rightHalf(page: Page, name: string) {
  const box = await tab(page, name).boundingBox()
  return { x: (box?.width ?? 100) - 8, y: 10 }
}

// Home, Code graph and the page that starts terminals, in that order.
async function openThree(page: Page) {
  await page.goto('/')
  await page.getByRole('button', { name: 'Code graph', exact: true }).click()
  await page.getByRole('button', { name: 'Terminals', exact: true }).click()
  await expect.poll(() => order(page)).toEqual(['Home', 'Code graph', 'New terminal'])
}

async function type(page: Page, text: string) {
  await page.locator('.terminal-view:not([hidden]) .terminal-host').click()
  await page.keyboard.type(text)
  await page.keyboard.press('Enter')
}

async function startShell(page: Page) {
  await page.getByRole('button', { name: 'Terminals', exact: true }).click()
  await openLaunch(page)
  await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
  await expect(page.getByRole('tab', { name: 'Shell 1' })).toBeVisible()
}

test.describe('moving a tab', () => {
  test('is done by dragging it before another one', async ({ page }) => {
    await openThree(page)
    await tab(page, 'New terminal').dragTo(tab(page, 'Code graph'), {
      targetPosition: { x: 4, y: 10 },
    })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
  })

  test('is done by dragging it after another one, in its right half', async ({ page }) => {
    await openThree(page)
    await tab(page, 'Code graph').dragTo(tab(page, 'New terminal'), {
      targetPosition: await rightHalf(page, 'New terminal'),
    })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
  })

  test('puts a tab last when it is dropped in the space after the last one', async ({ page }) => {
    await openThree(page)
    const box = await bar(page).boundingBox()
    await tab(page, 'Code graph').dragTo(bar(page), {
      targetPosition: { x: (box?.width ?? 800) - 20, y: 10 },
    })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
  })

  test('keeps the Home tab first: it is not dragged, and nothing is dropped before it', async ({
    page,
  }) => {
    await openThree(page)
    await expect(tab(page, 'Home')).not.toHaveAttribute('draggable', 'true')
    await tab(page, 'New terminal').dragTo(tab(page, 'Home'), { targetPosition: { x: 4, y: 10 } })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
  })

  test('changes nothing when the tab is let go anywhere else', async ({ page }) => {
    await openThree(page)
    await tab(page, 'New terminal').dragTo(page.locator('.content'))
    expect(await order(page)).toEqual(['Home', 'Code graph', 'New terminal'])
    // And the page that was showing is still the one that is.
    await expect(page.getByRole('tab', { name: 'New terminal' })).toHaveAttribute(
      'aria-selected',
      'true',
    )
  })

  test('is done from the keyboard with Alt and an arrow, and not for the Home tab', async ({
    page,
  }) => {
    await openThree(page)
    await page.getByRole('tab', { name: 'New terminal', exact: true }).press('Alt+ArrowLeft')
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
    await page.getByRole('tab', { name: 'New terminal', exact: true }).press('Alt+ArrowLeft')
    expect(await order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
    await page.getByRole('tab', { name: 'Home', exact: true }).press('Alt+ArrowRight')
    expect(await order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
  })

  test('keeps the page that was showing', async ({ page }) => {
    await openThree(page)
    await tab(page, 'Code graph').dragTo(tab(page, 'New terminal'), {
      targetPosition: await rightHalf(page, 'New terminal'),
    })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal', 'Code graph'])
    await expect(page.getByRole('tab', { name: 'New terminal' })).toHaveAttribute(
      'aria-selected',
      'true',
    )
  })

  test('keeps the Home tab, which has no close button and is not closed by the middle button', async ({
    page,
  }) => {
    await openThree(page)
    await expect(page.getByRole('button', { name: 'Close Home' })).toHaveCount(0)
    await expect(bar(page).getByRole('button', { name: /^Close / })).toHaveCount(2)
    await tab(page, 'Home').click({ button: 'middle' })
    await expect(tab(page, 'Home')).toBeVisible()
    await expect(page.getByRole('alertdialog')).toHaveCount(0)
    expect(await order(page)).toEqual(['Home', 'Code graph', 'New terminal'])
  })

  test('shows the Home page when every other tab is closed', async ({ page }) => {
    await openThree(page)
    await page.getByRole('button', { name: 'Close New terminal' }).click()
    await page.getByRole('button', { name: 'Close Code graph' }).click()
    await expect.poll(() => order(page)).toEqual(['Home'])
    await expect(page.getByRole('heading', { level: 1, name: 'Home' })).toBeVisible()
    await expect(page.getByRole('tab', { name: 'Home' })).toHaveAttribute('aria-selected', 'true')
  })
})

test.describe('closing a tab with the middle button', () => {
  test('closes a page that has nothing going on at once', async ({ page }) => {
    await openThree(page)
    await tab(page, 'Code graph').click({ button: 'middle' })
    await expect.poll(() => order(page)).toEqual(['Home', 'New terminal'])
    await expect(page.getByRole('alertdialog')).toHaveCount(0)
  })

  test('asks first for the terminals page while a session is running', async ({ page }) => {
    await page.goto('/')
    await startShell(page)
    await tab(page, 'Terminals').click({ button: 'middle' })
    const question = page.getByRole('alertdialog', { name: 'Close Terminals?' })
    await expect(question).toContainText(
      'One session is still running, and closing the tab ends it.',
    )
    // Nothing has closed.
    await expect(tab(page, 'Terminals')).toBeVisible()

    await question.getByRole('button', { name: 'Keep it open' }).click()
    await expect(question).toHaveCount(0)
    await expect(tab(page, 'Terminals')).toBeVisible()

    await tab(page, 'Terminals').click({ button: 'middle' })
    await question.getByRole('button', { name: 'Close Terminals' }).click()
    await expect(tab(page, 'Terminals')).toHaveCount(0)
    await expect(question).toHaveCount(0)
  })

  test('is asked of the close button too, and Escape keeps the tab', async ({ page }) => {
    await page.goto('/')
    await startShell(page)
    await page.getByRole('button', { name: 'Close Terminals' }).click()
    const question = page.getByRole('alertdialog', { name: 'Close Terminals?' })
    await expect(question).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(question).toHaveCount(0)
    await expect(tab(page, 'Terminals')).toBeVisible()
  })

  test('does not ask once the session has ended', async ({ page }) => {
    await page.goto('/')
    await startShell(page)
    await type(page, 'exit')
    await expect(page.getByText('The session ended.')).toBeVisible()
    await tab(page, 'Terminals').click({ button: 'middle' })
    await expect(tab(page, 'Terminals')).toHaveCount(0)
    await expect(page.getByRole('alertdialog')).toHaveCount(0)
  })

  test('counts the sessions that are running', async ({ page }) => {
    await page.goto('/')
    await startShell(page)
    await page.getByRole('tab', { name: 'New terminal' }).click()
    await launchCard(page, 'Shell').getByRole('button', { name: 'New shell' }).click()
    await expect(page.getByRole('tab', { name: 'Shell 2' })).toBeVisible()
    await tab(page, 'Terminals').click({ button: 'middle' })
    await expect(page.getByRole('alertdialog')).toContainText(
      '2 sessions are still running, and closing the tab ends them.',
    )
  })
})

test('asks first for the page of a run that is going on, and says it goes on', async ({ page }) => {
  // The step takes a while, so that the run is still going when its tab is closed.
  const answers = readFileSync(world().script, 'utf8')
  const slow = JSON.parse(answers) as Record<string, { delay_seconds: number }[]>
  slow.Work = [{ ...(slow.Work?.[0] ?? { delay_seconds: 0 }), delay_seconds: 6 }]
  writeFileSync(world().script, JSON.stringify(slow))
  try {
    await page.goto('/')
    await openSection(page, 'Definitions')
    await page
      .getByLabel('Side panel')
      .getByRole('button', { name: /Fixture_Run/ })
      .click()
    await page.getByRole('button', { name: 'Run', exact: true }).click()
    await page.getByRole('button', { name: 'Start run' }).click()
    await expect(page.getByText('Execution', { exact: true })).toBeVisible()
    // The tab of the run is the one showing, and is found by its name when it is not.
    const name = await page.locator('.tabbar .tab[data-selected="true"] [role="tab"]').innerText()
    const run = tab(page, name)

    await run.click({ button: 'middle' })
    const question = page.getByRole('alertdialog')
    await expect(question).toContainText(
      'This run is still going. Closing the tab does not stop it.',
    )
    await question.getByRole('button', { name: 'Keep it open' }).click()
    await expect(run).toBeVisible()

    // Once it has finished nothing is asked.
    // In the page of the run, and not the badges of the finished ones in the panel beside it.
    await expect(
      page.locator('.content').getByText('completed', { exact: true }).first(),
    ).toBeVisible({
      timeout: 30_000,
    })
    await run.click({ button: 'middle' })
    await expect(run).toHaveCount(0)
    await expect(page.getByRole('alertdialog')).toHaveCount(0)
  } finally {
    writeFileSync(world().script, answers)
  }
})
