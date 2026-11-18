import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'
import { TOKEN_HEADER } from './shared/constants.ts'
import { ports } from './shared/ports.ts'

const { web, server } = ports(process.env)

// The browser talks to the API through this proxy, which adds the per-launch
// token: the page never holds it, and the server still checks Host and Origin.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: web,
    strictPort: true,
    proxy: {
      '/api': {
        target: `http://127.0.0.1:${server}`,
        changeOrigin: true,
        // The bus is a WebSocket on /api/bus.
        ws: true,
        headers: { [TOKEN_HEADER]: process.env.SYNAPSE_DESKTOP_TOKEN ?? '' },
      },
    },
  },
  test: {
    environment: 'node',
    include: ['web/**/*.test.ts', 'server/**/*.test.ts', 'shared/**/*.test.ts'],
  },
})
