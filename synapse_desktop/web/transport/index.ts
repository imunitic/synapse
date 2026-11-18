// The Transport the app runs with: over a WebSocket when the page is served, over Tauri's IPC when it
// runs in the desktop app's window.

import type { Bus } from '../../shared/bus.ts'
import type { Transport } from '../../shared/transport.ts'
import { BusTransport } from './bus-transport.ts'
import { connectBus } from './socket-link.ts'
import { connectTauriBus, inTauri } from './tauri-link.ts'

let connected: Bus | null = null

// The page's bus, connected the first time something needs it.
export function bus(): Bus {
  connected ??= inTauri() ? connectTauriBus() : connectBus()
  return connected
}

export const transport: Transport = new BusTransport(bus)
