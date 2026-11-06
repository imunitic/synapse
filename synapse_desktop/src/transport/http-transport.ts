// The web-phase Transport: every call is a POST to the local API server.

import { API_PREFIX } from '../../shared/constants.ts'
import type {
  AppConfig,
  AppPaths,
  CliBinary,
  CliOptions,
  CliResult,
  DirEntry,
  RunAnswer,
  RunRequest,
  Transport,
  Unsubscribe,
} from '../../shared/transport.ts'

type Reply<T> = { ok: true; result: T } | { ok: false; error: string }

export class HttpTransport implements Transport {
  private async call<T>(method: string, params: object): Promise<T> {
    const response = await fetch(API_PREFIX + method, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(params),
    })
    const reply = (await response.json()) as Reply<T>
    if (!reply.ok) throw new Error(reply.error)
    return reply.result
  }

  readText(path: string): Promise<string> {
    return this.call('readText', { path })
  }

  readDir(path: string): Promise<DirEntry[]> {
    return this.call('readDir', { path })
  }

  cli(binary: CliBinary, args: string[], options?: CliOptions): Promise<CliResult> {
    return this.call('cli', { binary, args, stdin: options?.stdin })
  }

  getConfig(): Promise<AppConfig> {
    return this.call('getConfig', {})
  }

  setConfig(patch: Partial<AppConfig>): Promise<AppConfig> {
    return this.call('setConfig', { patch })
  }

  getPaths(): Promise<AppPaths> {
    return this.call('getPaths', {})
  }

  runRequest(executionId: string, request: RunRequest): Promise<RunAnswer> {
    return this.call('runRequest', { executionId, request })
  }

  // The server has no event stream or run control yet.
  watch(): Unsubscribe {
    throw new Error('watch is not available: the server has no event stream yet')
  }

  startRun(): Promise<{ executionId: string }> {
    return Promise.reject(new Error('startRun is not available yet'))
  }

  stopRun(): Promise<void> {
    return Promise.reject(new Error('stopRun is not available yet'))
  }
}
