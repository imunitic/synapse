import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'
import { SERVER_PORT, TOKEN_HEADER, WEB_PORT } from './shared/constants.ts'

// The browser talks to the API through this proxy, which adds the per-launch
// token: the page never holds it, and the server still checks Host and Origin.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: WEB_PORT,
    strictPort: true,
    proxy: {
      '/api': {
        target: `http://127.0.0.1:${SERVER_PORT}`,
        changeOrigin: true,
        headers: { [TOKEN_HEADER]: process.env.SYNAPSE_DESKTOP_TOKEN ?? '' },
      },
    },
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'server/**/*.test.ts', 'shared/**/*.test.ts'],
  },
})
