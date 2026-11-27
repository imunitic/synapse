// Which cards of the execution page are open, kept for each card in the browser. A card a person
// never folded or unfolded, or one whose choice cannot be read, has its default.

const cardKey = (card: string) => `card-open:${card}`

export function readCardOpen(
  storage: Pick<Storage, 'getItem'>,
  card: string,
  openByDefault: boolean,
): boolean {
  try {
    const held = storage.getItem(cardKey(card))
    if (held === '1') return true
    if (held === '0') return false
    return openByDefault
  } catch {
    return openByDefault
  }
}

// A choice that equals the default is forgotten, so the card behaves as if never touched.
export function writeCardOpen(
  storage: Pick<Storage, 'setItem' | 'removeItem'>,
  card: string,
  open: boolean,
  openByDefault: boolean,
): void {
  try {
    if (open === openByDefault) storage.removeItem(cardKey(card))
    else storage.setItem(cardKey(card), open ? '1' : '0')
  } catch {
    // The choice is only a convenience.
  }
}
