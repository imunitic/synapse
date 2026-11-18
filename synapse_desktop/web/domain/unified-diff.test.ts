import { describe, expect, it } from 'vitest'
import { parseUnifiedDiff } from './unified-diff.ts'

const MODIFIED = `diff --git a/src/a.txt b/src/a.txt
index 1111111..2222222 100644
--- a/src/a.txt
+++ b/src/a.txt
@@ -1,4 +1,4 @@ function one
 keep
-old line
+new line
 keep too
@@ -20,3 +20,4 @@
 tail
+added at the end
 more
 last
`

describe('parseUnifiedDiff', () => {
  it('has no files for an empty patch', () => {
    expect(parseUnifiedDiff('')).toEqual([])
    expect(parseUnifiedDiff('\n')).toEqual([])
  })

  it('reads the hunks of a changed file, with the number of each line in the old file and the new', () => {
    const [file] = parseUnifiedDiff(MODIFIED)
    expect(file).toMatchObject({
      path: 'src/a.txt',
      oldPath: null,
      status: 'modified',
      binary: false,
      added: 2,
      removed: 1,
    })
    expect(file!.hunks.map((h) => h.header)).toEqual([
      '@@ -1,4 +1,4 @@ function one',
      '@@ -20,3 +20,4 @@',
    ])
    expect(file!.hunks[0]!.lines).toEqual([
      { kind: 'context', text: 'keep', oldNumber: 1, newNumber: 1 },
      { kind: 'remove', text: 'old line', oldNumber: 2, newNumber: null },
      { kind: 'add', text: 'new line', oldNumber: null, newNumber: 2 },
      { kind: 'context', text: 'keep too', oldNumber: 3, newNumber: 3 },
    ])
    expect(file!.hunks[1]!.lines[1]).toEqual({
      kind: 'add',
      text: 'added at the end',
      oldNumber: null,
      newNumber: 21,
    })
  })

  it('reads several files, each with its own counts', () => {
    const files = parseUnifiedDiff(
      MODIFIED +
        `diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1 +1,2 @@
 one
+two
`,
    )
    expect(files.map((f) => [f.path, f.added, f.removed])).toEqual([
      ['src/a.txt', 2, 1],
      ['b.txt', 1, 0],
    ])
  })

  it('reads a deleted file, which is named by the side it had', () => {
    const [file] = parseUnifiedDiff(`diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 1111111..0000000
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-bye
-now
`)
    expect(file).toMatchObject({ path: 'gone.txt', status: 'deleted', added: 0, removed: 2 })
    expect(file!.hunks[0]!.lines.map((l) => l.oldNumber)).toEqual([1, 2])
  })

  it('reads a new file asked for by its path, whose old side is nothing', () => {
    const [file] = parseUnifiedDiff(`diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+hello
+world
`)
    expect(file).toMatchObject({ path: 'new.txt', status: 'added', added: 2, removed: 0 })
  })

  it('reads a renamed file as one file with where it was, with or without edits', () => {
    const files = parseUnifiedDiff(`diff --git a/big.txt b/moved.txt
similarity index 100%
rename from big.txt
rename to moved.txt
diff --git a/old.txt b/new-name.txt
similarity index 90%
rename from old.txt
rename to new-name.txt
index 1111111..2222222 100644
--- a/old.txt
+++ b/new-name.txt
@@ -1,2 +1,2 @@
 same
-before
+after
`)
    expect(files.map((f) => [f.status, f.oldPath, f.path])).toEqual([
      ['renamed', 'big.txt', 'moved.txt'],
      ['renamed', 'old.txt', 'new-name.txt'],
    ])
    expect(files[0]!.hunks).toEqual([])
    expect(files[1]).toMatchObject({ added: 1, removed: 1 })
  })

  it('marks a binary file, which has no hunks', () => {
    const [file] = parseUnifiedDiff(`diff --git a/blob.bin b/blob.bin
index 1111111..2222222 100644
Binary files a/blob.bin and b/blob.bin differ
`)
    expect(file).toMatchObject({ path: 'blob.bin', binary: true, hunks: [] })
  })

  it('reads a new file whose content was not kept: the lines its hunk says it has, and none to show', () => {
    const [file] = parseUnifiedDiff(`diff --git a/big.dat b/big.dat
new file mode 100644
--- /dev/null
+++ b/big.dat
@@ -0,0 +1,40000 @@
\\ Content not kept
`)
    expect(file).toMatchObject({
      path: 'big.dat',
      status: 'added',
      notKept: true,
      added: 40000,
      removed: 0,
    })
    expect(file!.hunks[0]!.lines).toEqual([
      { kind: 'note', text: 'Content not kept', oldNumber: null, newNumber: null },
    ])
  })

  it('keeps a change of mode only, which has no hunks, under its path', () => {
    const [file] = parseUnifiedDiff(`diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
`)
    expect(file).toMatchObject({ path: 'run.sh', status: 'modified', hunks: [] })
  })

  it('notes a missing newline at the end of a file without counting it as a line', () => {
    const [file] = parseUnifiedDiff(`diff --git a/x.txt b/x.txt
--- a/x.txt
+++ b/x.txt
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
`)
    expect(file).toMatchObject({ added: 1, removed: 1 })
    expect(file!.hunks[0]!.lines.map((l) => l.kind)).toEqual(['remove', 'note', 'add', 'note'])
    expect(file!.hunks[0]!.lines[1]!.text).toBe('No newline at end of file')
  })

  it('does not take a line of the text that starts with dashes or pluses for a header', () => {
    const [file] = parseUnifiedDiff(`diff --git a/doc.md b/doc.md
--- a/doc.md
+++ b/doc.md
@@ -1,3 +1,3 @@
 title
--- not a header
+++ not a header either
 end
`)
    expect(file).toMatchObject({ path: 'doc.md', added: 1, removed: 1 })
    expect(file!.hunks[0]!.lines.map((l) => [l.kind, l.text])).toEqual([
      ['context', 'title'],
      ['remove', '-- not a header'],
      ['add', '++ not a header either'],
      ['context', 'end'],
    ])
  })

  it('names a file with a space in its path, and one git quoted', () => {
    const files = parseUnifiedDiff(`diff --git a/with space.txt b/with space.txt
--- a/with space.txt
+++ b/with space.txt
@@ -1 +1 @@
-a
+b
diff --git "a/tab\\there.txt" "b/tab\\there.txt"
--- "a/tab\\there.txt"
+++ "b/tab\\there.txt"
@@ -1 +1 @@
-a
+b
diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
new file mode 100644
`)
    expect(files.map((f) => f.path)).toEqual(['with space.txt', 'tab\there.txt', 'café.txt'])
  })
})
