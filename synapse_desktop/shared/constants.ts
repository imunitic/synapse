// Values the Vite dev server, the host and the browser all have to agree on.

export const WEB_PORT = 5173
export const SERVER_PORT = 5174

// The end-to-end tests run beside a dev build, on ports of their own.
export const E2E_WEB_PORT = 5183
export const E2E_SERVER_PORT = 5184

// Every API request carries the per-launch token in this header.
export const TOKEN_HEADER = 'x-synapse-desktop-token'

// The bus: one WebSocket carrying the messages between the page and the host.
export const BUS_PATH = '/api/bus'
