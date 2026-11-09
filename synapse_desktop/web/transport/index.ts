// The Transport the app runs with. The Tauri build replaces this one line.

import { HttpTransport } from './http-transport.ts'
import type { Transport } from '../../shared/transport.ts'

export const transport: Transport = new HttpTransport()
