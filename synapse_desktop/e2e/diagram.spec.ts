import { expect, test, type Page } from './fixtures.ts'
import { openSection, setEditorText, sidePanel, uniqueName } from './helpers.ts'

// Opens a new pipeline in the editor with `steps` as its text and waits for its last step to be drawn.
async function drawPipeline(page: Page, steps: string[]) {
  await page.goto('/')
  await openSection(page, 'Definitions')
  await sidePanel(page).getByRole('button', { name: 'New pipeline' }).click()
  const body = steps.map((step) => `${step} [Harness => Claude, Prompt => "x"];`).join(' ')
  await setEditorText(page, `Pipeline ${uniqueName('Drawn')} { ${body} }`)
  const diagram = page.getByLabel('Diagram')
  await expect(diagram.getByLabel(`Step ${steps.at(-1)}, Claude`)).toBeVisible()
  return diagram
}

// Where the SVG sits inside the card's content box, and whether the card scrolls.
async function placement(page: Page) {
  return page.getByLabel('Diagram').evaluate((card) => {
    const svg = card.querySelector('svg.graph')!
    const style = getComputedStyle(card)
    const rect = card.getBoundingClientRect()
    const contentLeft = rect.left + card.clientLeft + parseFloat(style.paddingLeft)
    const contentRight =
      rect.left + card.clientLeft + card.clientWidth - parseFloat(style.paddingRight)
    const box = svg.getBoundingClientRect()
    return {
      leftGap: box.left - contentLeft,
      rightGap: contentRight - box.right,
      renderedWidth: box.width,
      widthAttribute: Number(svg.getAttribute('width')),
      scrollWidth: card.scrollWidth,
      clientWidth: card.clientWidth,
    }
  })
}

test('a long step name gets a box wide enough for it', async ({ page }) => {
  const diagram = await drawPipeline(page, ['Performance_Review_And_Signoff', 'Next'])
  const step = diagram.getByLabel('Step Performance_Review_And_Signoff, Claude')
  const sizes = await step.evaluate((node) => ({
    box: Number(node.querySelector('rect')!.getAttribute('width')),
    text: (node.querySelector('.graph-name') as SVGTextElement).getBBox().width,
  }))
  expect(sizes.box).toBeGreaterThan(sizes.text + 20)
  expect(sizes.box).toBeGreaterThan(150)
})

test('a short diagram is centred in its card', async ({ page }) => {
  await drawPipeline(page, ['First', 'Second'])
  const at = await placement(page)
  expect(Math.abs(at.leftGap - at.rightGap)).toBeLessThanOrEqual(2)
  expect(at.scrollWidth).toBe(at.clientWidth)
})

test('a long diagram scrolls and starts at the left', async ({ page }) => {
  const steps = Array.from({ length: 14 }, (_, i) => `Step_${i + 1}`)
  await drawPipeline(page, steps)
  const at = await placement(page)
  expect(at.scrollWidth).toBeGreaterThan(at.clientWidth)
  expect(Math.abs(at.leftGap)).toBeLessThanOrEqual(1)
  expect(at.renderedWidth).toBeCloseTo(at.widthAttribute, 0)
})
