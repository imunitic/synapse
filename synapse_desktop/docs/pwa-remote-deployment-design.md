# Private PWA remote-host design (proposed)

**Status:** detached implementation under review. Remote mode remains disabled and is not safe to expose.

## Preserve the current architecture

Synapse already serves the same React interface through two transports:

- Tauri desktop IPC to its embedded Rust host.
- Browser WebSocket to the Node host, using a token injected by the localhost Vite proxy.

Do not replace the shared protocol or introduce a separate application architecture. The existing Tauri desktop, local Node host and Node/Rust localhost end-to-end suites remain supported exactly as before.

## Accepted private deployment shape

```text
iPad / Android / browser (PWA)
               |
     private HTTPS origin
               |
   authenticated gateway (user/session owner)
          /                 \
  user A private route    user B private route
          |                   |
  user A Node container   user B Node container
  + PTY + CLIs + Git      + PTY + CLIs + Git
          |                   |
  user A credentials      user B credentials
  and storage volumes     and storage volumes
```

**One Node host per user.** Existing single-user terminal/session semantics may remain local to each host. The remote gateway owns authentication, session expiry and _authorization of the mapping_ between an authenticated principal and its host. The browser must never supply a trusted target container ID.

The backend must not be reachable directly from the public interface or another user's container, and the gateway-to-backend link must be independently authenticated or otherwise strongly bound to that isolated backend. No direct WebSocket upgrade may bypass gateway policy. Preserve Origin/Host checks and account for proxy headers, WebSocket reconnect, logout and session revocation.

## Container boundary

- Use a single reproducible application image, instantiated separately per user.
- Run as non-root with no privileged mode; drop unnecessary capabilities, restrict filesystem and network access, do not mount Docker's socket or arbitrary host paths.
- Keep per-user HOME, Claude/Codex login state, Vault checkout, Git credentials, workspace and terminal sessions in separate narrowly scoped persistent volumes.
- Control CPU, memory and process counts individually. Docker is isolation, not a virtual-machine-grade security guarantee: review the kernel-sharing risk before public/multi-tenant use.
- Separate live agents from deployment lifecycle. Rebuilds/restarts must account for work in progress and not discard unpushed changes.
- Keep user-owned remote Git repositories as the durable source of project content; no sole-copy manuscript or source work in disposable container storage.

## Provisional 8 GB VPS resource budget (not yet deployed)

These are **initial caps, not measured requirements**. Both users may run at the same time. Limit the Synapse workloads while retaining room for ReadBack and the operating system:

| Service                                           | Memory cap |  CPU cap | PID cap |
| ------------------------------------------------- | ---------: | -------: | ------: |
| User A Synapse Node host, CLI and PTYs (combined) |    1.5 GiB |  1.0 CPU |     256 |
| User B Synapse Node host, CLI and PTYs (combined) |    1.5 GiB |  1.0 CPU |     256 |
| Gateway                                           |    256 MiB | 0.25 CPU |      64 |

The total configured Synapse memory ceiling is **3.25 GiB**; it is not a reservation and does not mean that 4.75 GiB is guaranteed available for ReadBack. Host memory, filesystem cache, ReadBack's worker processes and other services must all be observed. CPU caps are quotas, not dedicated cores. Disk quotas, temporary build-space limits and per-user agent concurrency must be added before actual deployment.

- Initially permit **one active CLI agent task per user**; interactive PTYs still share that user's container cap.
- Measure peak memory, CPU, swap and OOM events for ReadBack and Synapse staging before enabling simultaneous agent sessions.
- If an agent exceeds its cap, expect possible termination rather than weakening container isolation or letting Synapse exhaust host RAM. Revise caps based on actual observed demand.
- No automatic user container restart while work is running, unless required for safety; preserve and sync unsent work first.

## Authenticated gateway contract (planning, not running)

- The browser continues using the existing same-origin `/api/bus` WebSocket URL. No new client-provided backend IDs or changes to Synapse bus messages.
- The gateway validates a real server-side authenticated session before any WebSocket upgrade, maps the verified user ID to a fixed operator-owned backend allowlist, and refuses unknown or mismatched mappings. See `server/gateway-routing.ts` for a **pure routing-policy helper only**, not an actual gateway or auth implementation.
- The gateway must use secure, HttpOnly cookies and anti-CSRF/Origin rules appropriate to the eventual private HTTPS origin; authenticate page delivery and WebSocket upgrades consistently.
- Expiry, logout or revocation must terminate already-upgraded sockets too; checking a cookie only at upgrade is not sufficient.
- Do not forward user-supplied destination, Host, identity, session or backend-token headers as trusted. The gateway injects only its own per-container internal token or equivalent private backend authentication.
- Node hosts must validate that gateway-injected credential and remain unreachable directly from user browsers or neighboring user containers. A private Docker network alone does not replace these checks.
- Authentication provider and session persistence mechanism remain design choices; no login UI or listener is enabled by the routing-policy helper.
- Testing needs end-to-end cases for forged user headers, cookie replay, revoked sessions during an open WebSocket, cross-container routing, and direct backend bypass.

## Gateway WebSocket implementation status (2026-11-20)

The branch includes a **detached, opt-in gateway transport** in `server/gateway.ts`, with integration tests in `server/gateway.test.ts`.

- Attaches to a provided Node HTTP server's existing `/api/bus` WebSocket upgrade path. Does **not** create a public listener, expose a login endpoint or replace any existing Synapse host.
- Requires exact public Host and Origin; rejects unknown paths.
- Requires caller-supplied _server-side_ session authentication and an independent session-validity callback. Both must be implemented securely before a remotely runnable gateway exists.
- Selects the per-user backend using `hostForPrincipal` and an operator-owned map. Never accepts target container selection from the browser.
- Connects to the existing private Node WebSocket with a gateway-owned per-container token and Origin; does not forward browser cookies or identity headers.
- Relays text WebSocket messages in both directions without interpreting or replacing Synapse's protocol. Refuses binary frames and bounds message/queued-byte sizes.
- Revalidates the session periodically and terminates both sockets on revocation, failure or disconnection. Applies per-user concurrent WebSocket caps (default two), protocol keepalive pings and pause/resume flow control between a high and low buffer watermark; disconnects a persistently stalled client after 20 seconds.
- Integration tests use fake private hosts and test-only session lookup; they verify routes, message relay, forged headers, refusal and revocation.

**Not yet implemented:** actual login and credential issuance, shared/restart-safe session store, private gateway HTTP frontend, backend remote-mode listener/Origin policy, container image/network/isolation, deployment and production hardening. Current `SYNAPSE_DESKTOP_HOST_MODE=remote` continues to refuse startup. None of this work is deployable yet.

## Opaque session-store foundation (2026-11-20)

The development branch adds `server/gateway-sessions.ts` with tests. It is a bounded, **in-memory** session store intended to be connected to the existing `attachGateway` callbacks later:

- Issue a 256-bit random, opaque session token; store only a SHA-256 digest for lookups, and map the record to one fixed user identity.
- Accept the token from a single strictly validated `synapse_session` cookie; reject absent, malformed and duplicated session cookies.
- Produce `Secure`, `HttpOnly`, `SameSite=Strict`, root-scoped cookie attributes; provide a matching cookie-clearing value.
- Enforce a configurable fixed expiry (default eight hours), bounded active sessions (default 32), per-user cap (default eight), per-session revocation and per-user revocation. When a user reaches their cap, the oldest _same-user_ session is evicted, and the WebSocket revalidation callback sees it as revoked.
- The gateway already revalidates active WebSockets periodically; its session callbacks are intentionally **not wired** to any public login listener yet.

**Not a production authentication system:** there is no verified login identity provider, brute-force protection, durable session persistence, key rotation, HTTPS gateway entry point, or container deployment. Restarting the gateway clears all sessions. A later hardened service must arrange secure login and session issuance, request authentication on _all_ HTTP and WebSocket paths, and logout/revocation across running sockets.

## Detached HTTP authentication handlers (2026-11-20)

The feature branch includes `server/gateway-http-auth.ts` and integration tests for `POST /auth/session`, `POST /auth/logout`, and `GET /auth/me`. This module attaches handlers only to an explicitly supplied HTTP server. It neither creates a listener nor modifies the existing localhost Node/Tauri hosts.

- Login uses a caller-supplied asynchronous `verifyCredentials(username, password)` function; only a verified, server-assigned user ID can acquire a session. No default credentials or passwords are included.
- Login returns a secure opaque session cookie and never exposes the raw token in a JSON response.
- Logout revokes the presented token and issues a clearing cookie. Session status returns only authenticated true/false, not credential or container details.
- Requests require exact Host; state-changing POST requires exact Origin. GET `/auth/me` accepts an absent Origin, as normal same-origin browser GET does, while rejecting a mismatched supplied Origin.
- Login accepts JSON media types with a charset parameter, limits request bytes, and enforces a 10-second total request-body read deadline (slow clients are disconnected).
- Login uses a bounded in-memory per-peer limiter. `gateway-trusted-peer.ts` accepts forwarded client addresses only from configured trusted TCP proxies, and rejects ambiguous or malformed forwarded addresses. Operators must configure the reverse proxy to strip untrusted forwarding headers. All login attempts, including successful ones, remain counted to bound expensive authentication work.
- Tests cover valid and invalid credentials, missing/expired cookies, logout reuse, origin rejection, method rejection, and rate limiting.

**Hardening required before deployment:** trusted identity provider integration and credentials storage; an HTTPS entrypoint that owns this exact Host/Origin; authenticated static application and asset delivery; network-facing rate-limit and connection controls; robust request timeout/body-size error responses; non-replica-safe in-memory state replacement or a deliberate single-instance deployment; session store cleanup and application lifecycle; and strict reverse-proxy configuration. The gateway's opt-in trusted-proxy resolver requires an explicit proxy IP allowlist. Reverse-proxy configuration and network isolation remain deployment prerequisites. No remote mode may be enabled solely by attaching these handlers.

## Operator-provisioned password verifier (2026-11-20)

The feature branch adds `server/gateway-password-verifier.ts` and unit tests, an optional verifier that may be injected into the HTTP auth layer's existing `verifyCredentials` callback. It uses Node's asynchronous scrypt with a 128-bit random salt, fixed `N=16384, r=8, p=1`, a 256-bit derived key, and timing-safe comparison. Unknown usernames follow the same derivation path using a dummy record.

- The operator must explicitly provide the username, stable user ID, and scrypt password hash through **external protected configuration**. No default account, password, hash, or environment fallback is embedded in the repository.
- Reject duplicate or malformed user IDs, usernames, and hash settings at initialization; no account auto-provisioning or browser-supplied user IDs.
- A provisioning workflow will later collect passwords without command-line arguments, shell history, CI logs, or commits. The supplied `hashGatewayPassword` helper is a library primitive, **not** an authenticated account-management interface.
- Unicode passwords are normalized to NFC during provisioning and verification for cross-device consistency. Scrypt concurrency is limited to two operations; saturation produces a distinct HTTP 503 busy response rather than claiming credentials are invalid.
- A deployed gateway must protect the account configuration on disk, validate backend host mappings against those fixed user IDs, and support credential changes and revocation.
- This verifier has not been attached to a public HTTP server or PWA login interface. Authentication remains **not deployable** until reverse-proxy, per-user container, login UI, static asset authorization, timeout, and network constraints are addressed.

## Protected PWA frontend foundation (2026-11-20)

The feature branch adds `server/gateway-protected-frontend.ts` and tests. It is an opt-in, detached handler on a caller-provided HTTP server, not a remotely runnable gateway.

- Requests for `/`, versioned frontend scripts, and the web manifest must present a valid server-side session cookie. Missing or revoked sessions are rejected.
- Frontend content comes from an explicit operator-supplied in-memory asset manifest. Request paths are matched exactly: no filesystem traversal, directory listing, implicit SPA fallback, or user-controlled filesystem paths.
- Only exact known authentication endpoints pass to the separate HTTP authentication handler. Other unhandled paths fail closed; the WebSocket bus remains an upgrade-only route.
- Valid authenticated assets receive no-store cache headers and restrictive browser security headers. Only GET and HEAD are accepted.
- Integration tests cover denial before login, delivery after session issuance, revocation, unexpected paths, malformed/encoded paths, reserved paths and missing assets.

**Remaining work:** securely load a real Vite build manifest and assets, compose the detached frontend/auth/WebSocket handlers on a single HTTPS-only gateway, ensure correct CSP and service-worker behavior, implement an unauthenticated login view without exposing the application bundle, and perform a browser/PWA integration test. Remote mode still refuses startup; no live listener, private containers, or deployment exists.

## Unified detached gateway composition (2026-11-20)

The feature branch now includes `server/gateway-private-entry.ts` and an HTTP integration test. Instead of attaching independent HTTP `request` listeners, the composer obtains the authentication and protected asset handlers and registers exactly **one** request dispatcher. Only the three exact auth endpoint paths reach the login/status/logout handler; all other HTTP requests go through the protected frontend allowlist (including ordinary requests to the WebSocket bus path, which are not upgrades). The WebSocket gateway remains a separate `upgrade` handler on the same server.

- The composer refuses a server with existing `request` or `upgrade` listeners, to avoid attaching to a live desktop host or causing overlapping HTTP responses.
- Account configuration, protected assets, identity mapping and the session store are supplied explicitly. The composer does not start an HTTP listener, read real secrets, enable remote mode or deploy services.
- The integration test exercises a missing session, login using a synthetic password hash, authenticated asset delivery, session status, logout, and denial after revocation.
- Existing direct handler APIs remain available to preserve standalone test coverage and compatibility.

**Review gate:** an independent code-reading review identified browser Origin behavior, trusted-proxy rate limiting, NFC password normalization, session eviction, WebSocket buffering, and redundant attachment concerns. These have implementation changes and tests, but browser-level behavior, proxy configuration, actual slow-client conditions, and macOS execution still require independent validation. Ask the reviewer to re-check the exact HTTP dispatch, authentication/session coupling, websocket upgrade path, backend isolation assumptions, and resource/timeout behavior before implementing a publicly reachable service. A safe unauthenticated login UI, a real build manifest loader, reverse-proxy configuration, hardened security headers, and Docker isolation are still outstanding.

## Host and deployment constraints

- The new remote mode must continue to fail closed until these protections are implemented and tested.
- Keep existing localhost test runner and Vite proxy in local mode.
- New gateway/container deployment tests supplement, not replace, Node/Rust desktop regressions.
- Synapse staging and eventual CI/CD will be separate from ReadBack's containers, secrets, deployment and volumes.
- ReadBack's current operator-reported usage is low; no VPS capacity change is assumed necessary yet. Measure RAM/CPU and reserve resources for ReadBack before running concurrent agent workloads.

## Security acceptance gates

1. Unauthenticated or expired sessions cannot connect to the gateway or WebSocket backend.
2. User A cannot route to user B's backend or access their terminals, repository paths, home, login credentials or volumes.
3. A direct request to a backend without the gateway's trusted credentials is rejected.
4. Container policy forbids cross-user mounts, Docker socket, host root, privileged capabilities and unbounded resource usage.
5. Browser Node/Rust localhost E2E tests and desktop build checks remain green.
6. Nothing is deployed or merged upstream before review.

## Work tracking

The design and intake task are in the separate private `dainalogue/aeris-synapse-vault` repository:

- `research/Synapse PWA architecture - initial audit.md`
- `inbox/Secure remote Node host for Synapse PWA - task draft.md`

Formal Synapse task registration still requires a configured local Synapse CLI.
