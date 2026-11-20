import { defineConfig, devices } from '@playwright/test'
import { E2E_WEB_PORT as WEB_PORT } from './shared/constants.ts'

if (process.env.E2E_WORLD === undefined) {
  throw new Error('Run the end-to-end tests with `npm run e2e`: they need a world made for them.')
}

// The app is started on the world that `npm run e2e` made, which is in the
// environment of this process.
export default defineConfig({
  testDir: 'e2e',
  testMatch: '*.spec.ts',
  // They share one app and one world, so they take turns.
  workers: 1,
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL: `http://127.0.0.1:${WEB_PORT}`,
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'node scripts/dev.ts',
    url: `http://127.0.0.1:${WEB_PORT}`,
    // The server works in a home and a data folder of the world's own.
    env: {
      HOME: process.env.E2E_HOME ?? '',
      USERPROFILE: process.env.E2E_HOME ?? '',
      XDG_DATA_HOME: process.env.E2E_DATA ?? '',
      // The shell of the terminals, whatever the machine's own is.
      SHELL: '/bin/sh',
      // Ports of their own, so that they run beside a dev build.
      SYNAPSE_DESKTOP_E2E: '1',
      // E2E always exercises the existing localhost host, regardless of the launcher's environment.
      SYNAPSE_DESKTOP_HOST_MODE: 'local',
    },
    reuseExistingServer: false,
    timeout: 30_000,
  },
})
