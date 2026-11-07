// How big the text of the app is: a percentage of the size the browser gives a page,
// from a short list, with the default a little over it since screens have grown.

export const TEXT_SIZES: readonly { percent: number; label: string }[] = [
  { percent: 100, label: 'Small' },
  { percent: 112.5, label: 'Default' },
  { percent: 125, label: 'Large' },
  { percent: 150, label: 'Larger' },
]

export const DEFAULT_TEXT_SIZE = 112.5

// A size that was kept, if it is one of those on offer, else the default.
export function parseTextSize(stored: string | null): number {
  const value = stored === null ? Number.NaN : Number(stored)
  return TEXT_SIZES.some((size) => size.percent === value) ? value : DEFAULT_TEXT_SIZE
}

// What a size in pixels at the browser's own size is at this size of the page, for what is
// drawn by a program with its own sizes, as a terminal is.
export function scaledPixels(pixels: number, percent: number): number {
  return Math.round((pixels * percent) / 100)
}
