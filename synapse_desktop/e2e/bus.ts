// Changes what the host answers a page, by the name of the message: the page's bus is let through to
// the real host, and the reply to the messages named here is replaced, or held back.

import type { Page } from '@playwright/test'
import type { Capabilities } from '../shared/protocol.ts'

export type Reply = { result: unknown } | { error: { code: string; message: string } } | 'never'

export type Override = (real: unknown, params: unknown) => Reply | Promise<Reply>

export interface BusOptions {
  // What the host says it can do, over what it says.
  capabilities?: Partial<Capabilities>
}

export async function overrideBus(
  page: Page,
  overrides: Record<string, Override>,
  options: BusOptions = {},
): Promise<void> {
  await page.routeWebSocket('**/api/bus', (page_) => {
    const host = page_.connectToServer()
    // What each request was, by id, to know which reply answers which message.
    const asked = new Map<string, { name: string; params: unknown }>()
    page_.onMessage((raw) => {
      const message = JSON.parse(String(raw)) as { kind: string; id?: string; name?: string }
      if (message.kind === 'request' && message.id !== undefined && message.name !== undefined) {
        asked.set(message.id, {
          name: message.name,
          params: (message as { params?: unknown }).params,
        })
      }
      host.send(raw)
    })
    host.onMessage((raw) => {
      const message = JSON.parse(String(raw)) as {
        kind: string
        id?: string
        result?: unknown
        capabilities?: object
      }
      if (message.kind === 'hello' && options.capabilities !== undefined) {
        page_.send(
          JSON.stringify({
            ...message,
            capabilities: { ...message.capabilities, ...options.capabilities },
          }),
        )
        return
      }
      const request = message.id === undefined ? undefined : asked.get(message.id)
      const override = request === undefined ? undefined : overrides[request.name]
      if (message.kind !== 'reply' || request === undefined || override === undefined) {
        page_.send(raw)
        return
      }
      void Promise.resolve(override(message.result, request.params)).then((reply) => {
        if (reply === 'never') return
        page_.send(JSON.stringify({ kind: 'reply', id: message.id, ...reply }))
      })
    })
  })
}
