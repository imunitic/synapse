import { useEffect, useState } from 'react'
import type { Capabilities } from '../../shared/protocol.ts'
import { bus } from '../transport/index.ts'

// What a page offers before its host has said what it can do: all of it, since a host that cannot
// do something says so in its first message, and the page is rarely seen before that.
const UNKNOWN: Capabilities = {
  host: 'node',
  shell: true,
  installActions: true,
}

// What the host the page is connected to can do, which the page offers only as far as it goes.
export function useCapabilities(): Capabilities {
  const [capabilities, setCapabilities] = useState<Capabilities>(
    () => bus().capabilities ?? UNKNOWN,
  )
  useEffect(() => bus().onHello(setCapabilities), [])
  return capabilities
}
