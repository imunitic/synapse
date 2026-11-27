import { useState, type ReactNode } from 'react'
import { readCardOpen, writeCardOpen } from '../domain/card-folds.ts'
import { ChevronIcon } from './icons.tsx'

// A card of the execution page that folds with a click on its title. A person's choice is kept
// per card, for every page, in local storage. Folded, it shows only its title and count.
export function FoldingCard({
  label,
  count,
  storageKey,
  openByDefault,
  children,
}: {
  label: string
  count: string
  storageKey: string
  openByDefault: boolean
  children: ReactNode
}) {
  const [open, setOpen] = useState(() => readCardOpen(localStorage, storageKey, openByDefault))
  function toggle() {
    setOpen(!open)
    writeCardOpen(localStorage, storageKey, !open, openByDefault)
  }
  return (
    <section className="card" aria-label={label}>
      <h2 className="card-title">
        <button type="button" className="card-fold" aria-expanded={open} onClick={toggle}>
          <ChevronIcon open={open} />
          {`${label} · ${count}`}
        </button>
      </h2>
      {open && children}
    </section>
  )
}
