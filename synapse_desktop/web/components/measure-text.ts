// How wide a text in the pipeline diagram is drawn, measured in the browser.
// The layout in domain/graph.ts takes this as an argument, so it never
// touches the page itself.

import type { MeasureText } from '../domain/graph.ts'

// The sizes of .graph-name and .graph-sub in shell.css, in rem. Both follow
// the root font size, which the Text size setting changes.
const FONT_REM = { name: 0.875, sub: 0.75 } as const

// The CSS font a text of this kind is drawn in.
export function graphFont(kind: 'name' | 'sub', rootPx: number, family: string): string {
  const size = FONT_REM[kind] * rootPx
  return kind === 'name' ? `600 ${size}px ${family}` : `${size}px ${family}`
}

let context: CanvasRenderingContext2D | null | undefined

function canvasContext(): CanvasRenderingContext2D | null {
  if (context === undefined) {
    context = document.createElement('canvas').getContext('2d')
  }
  return context
}

export const measureGraphText: MeasureText = (text, kind) => {
  const rootPx = parseFloat(getComputedStyle(document.documentElement).fontSize)
  const family = getComputedStyle(document.body).fontFamily
  const ctx = canvasContext()
  if (ctx === null) {
    // No canvas to measure with: a rough guess from the length.
    return text.length * FONT_REM[kind] * rootPx * 0.6
  }
  ctx.font = graphFont(kind, rootPx, family)
  return ctx.measureText(text).width
}
