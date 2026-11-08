// The lines that a change added to a text and removed from it, for showing what an
// agent did to a note.

export type DiffLine =
  | { kind: 'same' | 'added' | 'removed'; text: string }
  // Lines that are the same and are left out of what is shown.
  | { kind: 'gap'; hidden: number }

// Past this many pairs of lines the work is not done, and what is between the common
// beginning and the common end is shown as removed and then added.
const MOST_PAIRS = 4_000_000

function splitLines(text: string): string[] {
  if (text === '') return []
  const lines = text.split('\n')
  // A text that ends with a line feed has no last, empty line.
  return text.endsWith('\n') ? lines.slice(0, -1) : lines
}

// The longest run of lines the two share, in order, by the table of the lengths of the
// runs of every pair of beginnings.
function between(before: string[], after: string[]): DiffLine[] {
  if (before.length * after.length > MOST_PAIRS) {
    return [
      ...before.map((text): DiffLine => ({ kind: 'removed', text })),
      ...after.map((text): DiffLine => ({ kind: 'added', text })),
    ]
  }
  const rows = before.length + 1
  const columns = after.length + 1
  const table = new Uint32Array(rows * columns)
  for (let i = before.length - 1; i >= 0; i--) {
    for (let j = after.length - 1; j >= 0; j--) {
      table[i * columns + j] =
        before[i] === after[j]
          ? (table[(i + 1) * columns + j + 1] ?? 0) + 1
          : Math.max(table[(i + 1) * columns + j] ?? 0, table[i * columns + j + 1] ?? 0)
    }
  }
  const lines: DiffLine[] = []
  let i = 0
  let j = 0
  while (i < before.length && j < after.length) {
    if (before[i] === after[j]) {
      lines.push({ kind: 'same', text: before[i] ?? '' })
      i++
      j++
    } else if ((table[(i + 1) * columns + j] ?? 0) >= (table[i * columns + j + 1] ?? 0)) {
      lines.push({ kind: 'removed', text: before[i] ?? '' })
      i++
    } else {
      lines.push({ kind: 'added', text: after[j] ?? '' })
      j++
    }
  }
  for (; i < before.length; i++) lines.push({ kind: 'removed', text: before[i] ?? '' })
  for (; j < after.length; j++) lines.push({ kind: 'added', text: after[j] ?? '' })
  return lines
}

export function diffLines(before: string, after: string): DiffLine[] {
  const a = splitLines(before)
  const b = splitLines(after)
  let start = 0
  while (start < a.length && start < b.length && a[start] === b[start]) start++
  let endA = a.length
  let endB = b.length
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--
    endB--
  }
  return [
    ...a.slice(0, start).map((text): DiffLine => ({ kind: 'same', text })),
    ...between(a.slice(start, endA), b.slice(start, endB)),
    ...a.slice(endA).map((text): DiffLine => ({ kind: 'same', text })),
  ]
}

export function changeCount(lines: readonly DiffLine[]): { added: number; removed: number } {
  let added = 0
  let removed = 0
  for (const line of lines) {
    if (line.kind === 'added') added++
    if (line.kind === 'removed') removed++
  }
  return { added, removed }
}

// The changed lines with `context` lines of the same around each, and the rest as a gap
// that says how many lines it holds.
export function withContext(lines: readonly DiffLine[], context: number): DiffLine[] {
  const near = new Set<number>()
  lines.forEach((line, i) => {
    if (line.kind === 'added' || line.kind === 'removed') {
      for (let k = Math.max(0, i - context); k <= Math.min(lines.length - 1, i + context); k++) {
        near.add(k)
      }
    }
  })
  const shown: DiffLine[] = []
  let hidden = 0
  lines.forEach((line, i) => {
    if (near.has(i)) {
      if (hidden > 0) shown.push({ kind: 'gap', hidden })
      hidden = 0
      shown.push(line)
    } else {
      hidden++
    }
  })
  if (hidden > 0) shown.push({ kind: 'gap', hidden })
  return shown
}
