// Reading the unified diff that git prints: the files in it, and for each its hunks of lines with
// their numbers. It is the text of `git diff --no-color --find-renames`, which is what the host
// answers a request for changes with.

export type FileStatus = 'modified' | 'added' | 'deleted' | 'renamed'

export interface PatchLine {
  kind: 'context' | 'add' | 'remove' | 'note'
  text: string
  // The line's number in the old file and in the new one; null where it is not in that file.
  oldNumber: number | null
  newNumber: number | null
}

export interface Hunk {
  // The `@@ -a,b +c,d @@` line, with the name of the section git adds to it.
  header: string
  lines: PatchLine[]
}

export interface FileDiff {
  path: string
  // Where a renamed file was.
  oldPath: string | null
  status: FileStatus
  binary: boolean
  // Whether the content of a new file was left out of a record because it was past the limit: the
  // hunk says how many lines the file has, and there are none to show.
  notKept: boolean
  added: number
  removed: number
  hunks: Hunk[]
}

// What the engine writes in place of the lines of a new file it did not keep.
const NOT_KEPT = 'Content not kept'

// A path git quoted because of a character in it: the escapes of C, a byte as three octal digits.
function unquote(text: string): string {
  if (!text.startsWith('"') || !text.endsWith('"') || text.length < 2) return text
  const bytes: number[] = []
  const body = text.slice(1, -1)
  for (let i = 0; i < body.length; i++) {
    const c = body[i]!
    if (c !== '\\') {
      bytes.push(...new TextEncoder().encode(c))
      continue
    }
    const next = body[i + 1] ?? ''
    const octal = /^[0-3][0-7]{2}/.exec(body.slice(i + 1))
    if (octal !== null) {
      bytes.push(parseInt(octal[0], 8))
      i += 3
    } else {
      const named: Record<string, string> = { n: '\n', t: '\t', r: '\r', '"': '"', '\\': '\\' }
      bytes.push(...new TextEncoder().encode(named[next] ?? next))
      i += 1
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes))
}

// The path of a `--- a/x` or `+++ b/x` line, none for /dev/null.
function sidePath(line: string, prefix: '--- ' | '+++ '): string | null {
  const raw = unquote(line.slice(prefix.length).replace(/\t$/, ''))
  if (raw === '/dev/null') return null
  return raw.replace(/^[ab]\//, '')
}

// The path of a file whose header has no `---` and `+++` lines, from `a/x b/x`. Git quotes a name
// that has a special character in it, each half by itself. Two plain halves are the same path, so
// the middle is found by its length.
function pathOfHeader(rest: string): string {
  let second: string | null = null
  if (rest.startsWith('"')) {
    let end = 1
    while (end < rest.length && !(rest[end] === '"' && rest[end - 1] !== '\\')) end++
    second = rest.slice(end + 2)
  } else if (rest.includes(' "b/')) {
    second = rest.slice(rest.indexOf(' "b/') + 1)
  }
  if (second !== null) return unquote(second).replace(/^b\//, '')
  const length = (rest.length - 5) / 2
  if (Number.isInteger(length) && length > 0) {
    const first = rest.slice(2, 2 + length)
    if (rest === `a/${first} b/${first}`) return first
  }
  return rest.split(' b/').at(-1) ?? rest
}

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

// The files of a unified diff, in the order it has them. A patch that is empty has none.
export function parseUnifiedDiff(patch: string): FileDiff[] {
  const files: FileDiff[] = []
  let file: FileDiff | null = null
  let hunk: Hunk | null = null
  let oldNumber = 0
  let newNumber = 0
  // How many lines the hunk being read says it adds.
  let newCount = 0
  // Until the first hunk a file has only its header.
  let renamedFrom: string | null = null
  let renamedTo: string | null = null
  let side: { from: string | null; to: string | null } | null = null

  const finish = () => {
    if (file === null) return
    if (renamedTo !== null) {
      file.path = renamedTo
      file.oldPath = renamedFrom
      file.status = 'renamed'
    } else if (side !== null) {
      if (file.status === 'deleted' && side.from !== null) file.path = side.from
      else if (side.to !== null) file.path = side.to
    }
    files.push(file)
    file = null
    hunk = null
    renamedFrom = renamedTo = null
    side = null
  }

  const lines = patch === '' ? [] : patch.replace(/\n$/, '').split('\n')
  for (const line of lines) {
    if (line.startsWith('diff --git ')) {
      finish()
      file = {
        path: pathOfHeader(line.slice('diff --git '.length)),
        oldPath: null,
        status: 'modified',
        binary: false,
        notKept: false,
        added: 0,
        removed: 0,
        hunks: [],
      }
      side = { from: null, to: null }
      continue
    }
    if (file === null) continue
    if (
      hunk === null ||
      !/^[ +\\-]/.test(line) ||
      line.startsWith('--- ') ||
      line.startsWith('+++ ')
    ) {
      // The header, or the start of a hunk.
      const start = HUNK.exec(line)
      if (start !== null) {
        hunk = { header: line, lines: [] }
        file.hunks.push(hunk)
        oldNumber = Number(start[1])
        newNumber = Number(start[3])
        newCount = start[4] === undefined ? 1 : Number(start[4])
        continue
      }
      if (hunk === null) {
        if (line.startsWith('new file mode')) file.status = 'added'
        else if (line.startsWith('deleted file mode')) file.status = 'deleted'
        else if (line.startsWith('rename from ')) renamedFrom = unquote(line.slice(12))
        else if (line.startsWith('rename to ')) renamedTo = unquote(line.slice(10))
        else if (line.startsWith('--- ') && side !== null) side.from = sidePath(line, '--- ')
        else if (line.startsWith('+++ ') && side !== null) side.to = sidePath(line, '+++ ')
        else if (line.startsWith('Binary files ') || line.startsWith('GIT binary patch')) {
          file.binary = true
        }
        continue
      }
    }
    if (hunk === null) continue
    if (line.startsWith('\\')) {
      const text = line.slice(2)
      hunk.lines.push({ kind: 'note', text, oldNumber: null, newNumber: null })
      if (text === NOT_KEPT) {
        file.notKept = true
        file.added = newCount
      }
    } else if (line.startsWith('+')) {
      hunk.lines.push({ kind: 'add', text: line.slice(1), oldNumber: null, newNumber: newNumber++ })
      file.added += 1
    } else if (line.startsWith('-')) {
      hunk.lines.push({
        kind: 'remove',
        text: line.slice(1),
        oldNumber: oldNumber++,
        newNumber: null,
      })
      file.removed += 1
    } else {
      hunk.lines.push({
        kind: 'context',
        text: line.slice(1),
        oldNumber: oldNumber++,
        newNumber: newNumber++,
      })
    }
  }
  finish()
  return files
}
