// Values the Vite dev server, the API server and the browser all have to agree on.

export const WEB_PORT = 5173
export const SERVER_PORT = 5174

// Every API request carries the per-launch token in this header.
export const TOKEN_HEADER = 'x-synapse-desktop-token'

// Requests are POSTed to API_PREFIX + method name.
export const API_PREFIX = '/api/call/'
