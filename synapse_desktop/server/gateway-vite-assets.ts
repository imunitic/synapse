// Opt-in loader for the Vite production build. It constructs an exact,
// in-memory asset allowlist; the HTTP request path is NEVER used as a disk path.
// This module does not start a server or enable remote hosting.
import { readFile, realpath, stat } from 'node:fs/promises'
import { extname, relative, resolve, sep } from 'node:path'
import type { ProtectedAsset } from './gateway-protected-frontend.ts'

const MAX_FILE_BYTES = 8 * 1024 * 1024
const MAX_TOTAL_BYTES = 64 * 1024 * 1024
const MAX_ASSETS = 256

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.wasm': 'application/wasm',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
}

interface ManifestEntry {
  readonly file?: unknown
  readonly css?: unknown
  readonly assets?: unknown
}

function safeAssetPath(value: unknown): value is string {
  if (typeof value !== 'string' || !/^assets\/[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value))
    return false
  const parts = value.split('/')
  if (parts.some((part) => part === '' || part === '.' || part === '..')) return false
  return Object.hasOwn(CONTENT_TYPES, extname(value).toLowerCase())
}

function inside(root: string, candidate: string): boolean {
  const path = relative(root, candidate)
  return path !== '' && path !== '..' && !path.startsWith(`..${sep}`) && !path.startsWith(sep)
}

async function loadBounded(root: string, path: string): Promise<Buffer> {
  const filename = resolve(root, path)
  if (!inside(root, filename)) throw new Error('asset escapes build directory')
  const real = await realpath(filename)
  if (!inside(root, real)) throw new Error('asset symlink escapes build directory')
  const info = await stat(real)
  if (!info.isFile() || info.size > MAX_FILE_BYTES) throw new Error('invalid build asset size')
  const content = await readFile(real)
  if (content.length > MAX_FILE_BYTES) throw new Error('invalid build asset size')
  return content
}

export async function loadViteProtectedAssets(
  buildDirectory: string,
): Promise<ReadonlyMap<string, ProtectedAsset>> {
  const root = await realpath(buildDirectory)
  const manifestBytes = await loadBounded(root, '.vite/manifest.json')
  let parsed: unknown
  try {
    parsed = JSON.parse(manifestBytes.toString('utf8')) as unknown
  } catch {
    throw new Error('invalid Vite production manifest')
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('invalid Vite production manifest')
  }
  if (!Object.hasOwn(parsed, 'index.html')) throw new Error('missing Vite entrypoint')
  const files = new Set<string>()
  for (const entry of Object.values(parsed as Record<string, ManifestEntry>)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error('invalid Vite manifest entry')
    }
    if (entry.file !== undefined) files.add(entry.file as string)
    for (const key of ['css', 'assets'] as const) {
      const array = entry[key]
      if (array === undefined) continue
      if (!Array.isArray(array)) throw new Error('invalid Vite manifest asset list')
      for (const file of array) files.add(file as string)
    }
  }
  if (files.size === 0 || files.size > MAX_ASSETS) throw new Error('invalid asset count')
  const index = await loadBounded(root, 'index.html')
  const assets = new Map<string, ProtectedAsset>([
    ['/', { content: index, contentType: 'text/html; charset=utf-8' }],
  ])
  let totalBytes = index.length
  for (const path of files) {
    if (!safeAssetPath(path)) throw new Error('unsafe Vite asset path')
    const content = await loadBounded(root, path)
    totalBytes += content.length
    if (totalBytes > MAX_TOTAL_BYTES) throw new Error('Vite build exceeds asset budget')
    const contentType = CONTENT_TYPES[extname(path).toLowerCase()]
    if (!contentType) throw new Error('unsupported Vite asset type')
    assets.set(`/${path}`, { content, contentType })
  }
  return assets
}
