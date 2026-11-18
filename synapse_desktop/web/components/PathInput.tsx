// A text input for a folder, with a 📁 button beside it in the desktop app that opens the system's
// folder dialog and puts the chosen path in the input. Served to a browser, it is the bare input.

import { open } from '@tauri-apps/plugin-dialog'
import type { InputHTMLAttributes } from 'react'
import { inTauri } from '../transport/tauri-link.ts'
import { isAbsolutePath } from '../domain/vaults.ts'

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange'> & {
  value: string
  onChange: (value: string) => void
  // Called with the folder chosen in the dialog, after `onChange`, for an input that saves when
  // it is left: choosing is not leaving.
  onPick?: (value: string) => void
}

export function PathInput({ value, onChange, onPick, className, ...rest }: Props) {
  const input = (
    <input
      {...rest}
      className={className}
      type="text"
      value={value}
      spellCheck={false}
      onChange={(event) => onChange(event.target.value)}
    />
  )
  if (!inTauri()) return input

  async function choose() {
    const start = value.trim()
    const chosen = await open({
      directory: true,
      defaultPath: isAbsolutePath(start) ? start : undefined,
    })
    if (typeof chosen !== 'string') return
    onChange(chosen)
    onPick?.(chosen)
  }

  // The wrapper takes the input's `grow`, so a row lays it out as it laid the input out.
  const grows = className?.split(' ').includes('grow') === true
  return (
    <span className={grows ? 'path-input grow' : 'path-input'}>
      {input}
      <button
        type="button"
        className="secondary path-pick"
        aria-label="Choose a folder"
        title="Choose a folder"
        disabled={rest.disabled}
        onClick={() => void choose()}
      >
        📁
      </button>
    </span>
  )
}
