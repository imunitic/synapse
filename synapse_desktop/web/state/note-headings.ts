// How the Outline sidebar reaches the headings of a note page: the page registers, per note path,
// how to scroll its body to a heading path and how to open the comment box under one, while it is
// on the page. The outline looks them up when a heading in it is clicked.

export interface NoteHeadings {
  // Scrolls the note body to the heading with this doc-map path.
  scrollTo: (section: string) => void
  // Opens the comment box under the heading with this path, or the whole-note one for null.
  comment: (section: string | null) => void
}

// Kept on the global object, so that a copy of this module loaded again in development (a hot
// reload) finds the pages that registered with the one before.
const global = globalThis as typeof globalThis & {
  __synapseNoteHeadings?: Map<string, NoteHeadings>
}
global.__synapseNoteHeadings ??= new Map()
const registered = global.__synapseNoteHeadings

// Registers a note page's headings; what it returns unregisters them, if they are still the ones
// registered.
export function registerNoteHeadings(path: string, headings: NoteHeadings): () => void {
  registered.set(path, headings)
  return () => {
    if (registered.get(path) === headings) registered.delete(path)
  }
}

export function noteHeadings(path: string): NoteHeadings | null {
  return registered.get(path) ?? null
}
