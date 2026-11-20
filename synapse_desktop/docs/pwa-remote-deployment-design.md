# Private PWA remote-host design (proposed)

**Status:** design only. The remote host is not implemented or safe to expose.

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

**One Node host per user.** Existing single-user terminal/session semantics may remain local to each host. The remote gateway owns authentication, session expiry and *authorization of the mapping* between an authenticated principal and its host. The browser must never supply a trusted target container ID.

The backend must not be reachable directly from the public interface or another user's container, and the gateway-to-backend link must be independently authenticated or otherwise strongly bound to that isolated backend. No direct WebSocket upgrade may bypass gateway policy. Preserve Origin/Host checks and account for proxy headers, WebSocket reconnect, logout and session revocation.

## Container boundary

- Use a single reproducible application image, instantiated separately per user.
- Run as non-root with no privileged mode; drop unnecessary capabilities, restrict filesystem and network access, do not mount Docker's socket or arbitrary host paths.
- Keep per-user HOME, Claude/Codex login state, Vault checkout, Git credentials, workspace and terminal sessions in separate narrowly scoped persistent volumes.
- Control CPU, memory and process counts individually. Docker is isolation, not a virtual-machine-grade security guarantee: review the kernel-sharing risk before public/multi-tenant use.
- Separate live agents from deployment lifecycle. Rebuilds/restarts must account for work in progress and not discard unpushed changes.
- Keep user-owned remote Git repositories as the durable source of project content; no sole-copy manuscript or source work in disposable container storage.

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
