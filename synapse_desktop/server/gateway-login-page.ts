// Minimal unauthenticated gateway login page. No Synapse application assets,
// user data, backend mappings, or authentication tokens are embedded here.
// The caller provides the HTTPS origin; this module never opens a listener.
import type { IncomingMessage, ServerResponse } from 'node:http'

const LOGIN_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Sign in · Synapse</title>
<link rel="stylesheet" href="/login.css">
<script src="/login.js" defer></script>
</head>
<body>
<main>
<h1>Synapse</h1>
<form id="login-form">
<label for="username">Username</label>
<input id="username" name="username" type="text" autocomplete="username" maxlength="128" required>
<label for="password">Password</label>
<input id="password" name="password" type="password" autocomplete="current-password" maxlength="1024" required>
<button type="submit">Sign in</button>
<p id="status" role="status" aria-live="polite"></p>
</form>
</main>
</body>
</html>`

const LOGIN_JS = `'use strict'
const form = document.getElementById('login-form')
const status = document.getElementById('status')
const button = form.querySelector('button')
form.addEventListener('submit', async (event) => {
  event.preventDefault()
  button.disabled = true
  status.textContent = ''
  const username = form.elements.namedItem('username').value
  const password = form.elements.namedItem('password').value
  form.elements.namedItem('password').value = ''
  try {
    const response = await fetch('/auth/session', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
      cache: 'no-store',
    })
    if (response.ok) {
      window.location.replace('/')
      return
    }
    status.textContent = response.status === 429
      ? 'Too many attempts. Please try again later.'
      : response.status === 503
        ? 'Sign in is temporarily unavailable.'
        : 'Unable to sign in. Check your credentials.'
  } catch {
    status.textContent = 'Connection unavailable. Please try again.'
  } finally {
    button.disabled = false
  }
})
`

const LOGIN_CSS = `body{font:1rem system-ui,sans-serif;max-width:26rem;margin:12vh auto;padding:1.5rem;color:#eaeaf7;background:#151523}main{padding:1.5rem;border:1px solid #42425c;border-radius:1rem}form{display:grid;gap:.75rem}input,button{font:inherit;padding:.7rem;border-radius:.4rem}button{cursor:pointer}#status{min-height:1.5em}`

const ASSETS = new Map([
  ['/login', { content: LOGIN_HTML, type: 'text/html; charset=utf-8' }],
  ['/login.js', { content: LOGIN_JS, type: 'text/javascript; charset=utf-8' }],
  ['/login.css', { content: LOGIN_CSS, type: 'text/css; charset=utf-8' }],
])

export function createGatewayLoginPageHandler(publicHost: string) {
  return (request: IncomingMessage, response: ServerResponse): void => {
    const asset = ASSETS.get(request.url ?? '')
    if (!asset) return
    const headers = {
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'X-Frame-Options': 'DENY',
      'Content-Security-Policy':
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    }
    if (request.headers.host !== publicHost) {
      response.writeHead(403, headers).end()
      return
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405, { ...headers, Allow: 'GET, HEAD' }).end()
      return
    }
    const bytes = Buffer.from(asset.content)
    response.writeHead(200, {
      ...headers,
      'Content-Type': asset.type,
      'Content-Length': bytes.length,
    })
    response.end(request.method === 'HEAD' ? undefined : bytes)
  }
}
