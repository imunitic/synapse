// The names to show for a list of folders: each folder's own name, and for the names that
// more than one folder has, the name of the folder it is in before it.
export function workspaceNames(paths: readonly string[]): string[] {
  const names = paths.map((path) => workspaceLabel(path))
  const count = new Map<string, number>()
  for (const { name } of names) count.set(name, (count.get(name) ?? 0) + 1)
  return names.map(({ name, parent }) => {
    if ((count.get(name) ?? 0) < 2) return name
    const above = workspaceLabel(parent).name
    return above === '' || above === parent ? name : `${above}/${name}`
  })
}

// How a workspace, the folder a harness works in, is shown: its own name, and the folder
// it is in.
export function workspaceLabel(path: string): { name: string; parent: string } {
  const trimmed = path.length > 1 ? path.replace(/[\\/]+$/, '') : path
  const cut = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'))
  if (cut < 0) return { name: trimmed, parent: '' }
  const name = trimmed.slice(cut + 1)
  const parent = trimmed.slice(0, cut)
  // The root, and a folder directly in it.
  if (name === '') return { name: trimmed, parent: '' }
  return { name, parent: parent === '' ? trimmed.slice(0, cut + 1) : parent }
}
