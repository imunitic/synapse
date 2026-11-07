// Stroke icons, drawn at 24 by 24 and sized by the caller. They are decoration:
// the button around each one carries the accessible name.

import type { ReactNode } from 'react'

function Icon({ size = 18, children }: { size?: number; children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  )
}

export const SidebarIcon = () => (
  <Icon>
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <path d="M9 4v16" />
  </Icon>
)

export const DefinitionsIcon = () => (
  <Icon>
    <path d="M4 6h16M4 12h16M4 18h10" />
  </Icon>
)

export const ExecutionsIcon = () => (
  <Icon>
    <path d="M7 5l12 7-12 7z" />
  </Icon>
)

export const TerminalIcon = () => (
  <Icon>
    <path d="M5 7l5 5-5 5M12 17h7" />
  </Icon>
)

export const ChevronIcon = ({ open }: { open: boolean }) => (
  <Icon size={14}>
    <path d={open ? 'M6 9l6 6 6-6' : 'M9 6l6 6-6 6'} />
  </Icon>
)

export const FolderIcon = ({ open }: { open: boolean }) => (
  <Icon size={15}>
    {open ? (
      <path d="M3 8a2 2 0 012-2h4l2 2h8a2 2 0 012 2v1H7.5a2 2 0 00-1.9 1.4L3 18V8zM3 18l2.6-6.6A2 2 0 017.5 10H22l-2.4 7.4A2 2 0 0117.7 19H5a2 2 0 01-2-1z" />
    ) : (
      <path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" />
    )}
  </Icon>
)

export const NoteIcon = () => (
  <Icon size={15}>
    <path d="M7 3h7l5 5v11a2 2 0 01-2 2H7a2 2 0 01-2-2V5a2 2 0 012-2z" />
    <path d="M14 3v5h5M9 13h6M9 17h6" />
  </Icon>
)

export const VaultIcon = () => (
  <Icon>
    <path d="M5 4h11a3 3 0 013 3v13H8a3 3 0 01-3-3V4z" />
    <path d="M5 17a3 3 0 013-3h11M9 8h6" />
  </Icon>
)

export const GraphIcon = () => (
  <Icon>
    <circle cx="6" cy="6" r="2.2" />
    <circle cx="18" cy="8" r="2.2" />
    <circle cx="9" cy="18" r="2.2" />
    <path d="M8 7l8 1M7 8l2 8M16.6 10l-6 6.4" />
  </Icon>
)

export const HomeIcon = () => (
  <Icon>
    <path d="M4 11l8-7 8 7M6 10v9h12v-9M10 19v-5h4v5" />
  </Icon>
)

export const SettingsIcon = () => (
  <Icon>
    <path d="M4 7h10M18 7h2M4 17h2M10 17h10" />
    <circle cx="16" cy="7" r="2" />
    <circle cx="8" cy="17" r="2" />
  </Icon>
)

export const PlusIcon = () => (
  <Icon size={16}>
    <path d="M12 5v14M5 12h14" />
  </Icon>
)

export const PencilIcon = () => (
  <Icon size={16}>
    <path d="M4 20l1-4L16.5 4.5a2.1 2.1 0 0 1 3 3L8 19l-4 1z" />
    <path d="M14.5 6.5l3 3" />
  </Icon>
)

export const CloseIcon = () => (
  <Icon size={12}>
    <path d="M6 6l12 12M18 6L6 18" />
  </Icon>
)

export const RefreshIcon = () => (
  <Icon size={16}>
    <path d="M20 12a8 8 0 1 1-2.3-5.7" />
    <path d="M20 4v5h-5" />
  </Icon>
)
