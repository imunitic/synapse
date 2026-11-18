// The tests share one host, which keeps terminal sessions after a page has gone, so each test ends
// what it left, and starts on a host with none.

import { test as base } from '@playwright/test'
import { WebSocket } from 'ws'
import { E2E_WEB_PORT as WEB_PORT } from '../shared/constants.ts'

export * from '@playwright/test'

// How long a start that was under way when a test ended is given to be made before the sweep that
// ends it.
const SETTLE_MS = 150

type Reply = { kind: string; id?: string; result?: { sessions?: { session: string }[] } }

async function endSessions(): Promise<void> {
  // Through the dev server, which adds the token as it does for the page.
  const socket = new WebSocket(`ws://127.0.0.1:${WEB_PORT}/api/bus`, {
    headers: { origin: `http://127.0.0.1:${WEB_PORT}` },
  })
  const replies = new Map<string, (reply: Reply) => void>()
  socket.on('message', (raw) => {
    const reply = JSON.parse(String(raw)) as Reply
    if (reply.kind === 'reply' && reply.id !== undefined) replies.get(reply.id)?.(reply)
  })
  await new Promise<void>((resolve, reject) => {
    socket.once('open', () => resolve())
    socket.once('error', reject)
  })
  let next = 0
  const ask = (name: string, params: object) =>
    new Promise<Reply>((resolve) => {
      const id = `e${next++}`
      replies.set(id, resolve)
      socket.send(JSON.stringify({ kind: 'request', id, name, params }))
    })
  const listed = await ask('terminal.list', {})
  for (const { session } of listed.result?.sessions ?? []) {
    await ask('terminal.close', { session })
  }
  socket.close()
}

// The cards of the Terminals page open shut, which is how a person finds them. A test that is not
// about that starts with them open, so that it can reach the lists in them: this opens them once
// for each tab, and leaves the browser's own memory alone after that.
const OPEN_CARDS = `
  if (!sessionStorage.getItem('e2e-cards-opened')) {
    sessionStorage.setItem('e2e-cards-opened', '1')
    for (const card of ['Claude', 'Codex', 'Opencode']) {
      localStorage.setItem('synapse-desktop.launch-open.' + card, 'true')
    }
  }
`

export const test = base.extend<{ endedSessions: void }>({
  page: async ({ page }, use) => {
    await page.addInitScript(OPEN_CARDS)
    await use(page)
  },
  endedSessions: [
    // Playwright wants the first argument to be a destructuring pattern, even of nothing.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      // At the start as well, so that a test never begins on what another left, whatever its page
      // was doing when it ended.
      await endSessions().catch(() => undefined)
      await use()
      // A session may still have been being started when the page went away, which the host then
      // goes on to make: a second sweep after a short wait ends that too.
      await endSessions().catch(() => undefined)
      await new Promise((resolve) => setTimeout(resolve, SETTLE_MS))
      await endSessions().catch(() => undefined)
    },
    { auto: true },
  ],
})
