# Private staging foundation (not deployment authorization)

The repository contains `synapse_desktop/Dockerfile.private-host`, a Node 24 image for the existing **local-mode** Node host. From the repository root, its intended build command is:

```sh
docker build -f synapse_desktop/Dockerfile.private-host -t synapse-private-host:dev .
```

This is **not yet a deployable PWA stack**. The image has no published port. The repository has a detached authenticated gateway dispatcher, login page, session store and protected Vite asset loader, and an opt-in loopback-only gateway entrypoint, but no provisioned runtime configuration, HTTPS termination or complete container topology. The Node process binds `127.0.0.1` in its own network namespace and requires a separately provisioned private gateway with a compatible namespace and explicit backend token/origin. Never map its port to the public interface or enable `SYNAPSE_DESKTOP_HOST_MODE=remote`.

## Architecture decision: isolated backend containers (2026-11-24)

**Chosen direction:** one authenticated HTTPS-facing gateway routes each user to a separately provisioned Node backend container through **private container networking**, rather than sharing a network namespace between all users. This is a design decision, **not an implemented topology**.

- Each user gets a distinct backend container, writable home/workspace volume, backend token, and agent/Git authentication context. No user shares a terminal or writable workspace with another user.
- Only the gateway is reachable through the authorized HTTPS reverse proxy. Backend services must not publish host/public ports. Gateway routing must derive the backend from the authenticated server-side user identity, never a client-supplied container address or token.
- The current Node backend binds to `127.0.0.1` and the gateway currently validates loopback-only backend URLs. **Neither can communicate across ordinary separate Docker namespaces as written.** Implement a narrowly scoped private-network transport and corresponding binding/validation policy before attempting this topology. Do not silently relax either check or enable `SYNAPSE_DESKTOP_HOST_MODE=remote`.
- Private networking alone does not guarantee user isolation. Explicitly restrict east-west traffic, container privileges, mounted paths, and access to Docker control sockets; verify that user A cannot connect to user B's backend even with a known address.
- Adding user C should be provisioning/configuration (new isolated backend, volume, secret and authenticated routing entry), not an application code change. A container per user is the scaling unit, subject to VPS resource limits.
- Before any deployment: prove gateway-to-container WebSocket/PTY flow, session revocation, two-user cross-access rejection, and clean container restart in automated tests. Keep secrets out of the repository and CI logs. Do not deploy or alter the VPS without fresh authorization.

Before an authorized private staging deployment:

1. Build the frontend with `npm run build` in `synapse_desktop`. The opt-in gateway entrypoint is `npm run gateway:private` and requires `SYNAPSE_PRIVATE_GATEWAY_CONFIG` pointing to an operator-owned JSON file (never commit the file). It loads the Vite build from `buildDirectory` and uses existing login/logout and session issuance; do not build a second authentication stack. The required JSON fields are `port` (loopback listening port), `publicHost` (external HTTPS host and optional port), `publicOrigin` (matching exact HTTPS origin), `buildDirectory`, `accounts` (username, userId, scrypt passwordHash) and `hosts` (userId, loopback backend URL, backendToken, backendOrigin). No accounts or backend tokens are supplied by the repository. HTTPS termination and correct Host/Origin forwarding are required for a real browser session; this command alone is not a browser demo. Keep the listener loopback-only until an explicitly authorized HTTPS reverse-proxy deployment.
2. Implement the chosen isolated per-user backend container topology and persistent workspace volumes, including private gateway-to-backend transport and network access controls. Two gateway users must never share the same Node host/terminal namespace.
3. Supply a unique backend token per private host at runtime via secret injection, not Docker build args, committed files or browser headers. Set `SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN` to the gateway's exact private Origin.
4. Keep the authenticated gateway → Node bus → real PTY smoke test green, and verify reconnect/revocation and two-user separation in CI. Confirm the Docker image actually builds and that the Node 24 PTY native dependency loads on the target architecture; this has not yet been demonstrated.
5. Only after separate authorization, select a private staging hostname and TLS/auth approach, review VPS resource isolation with ReadBack, and perform a reversible staging rollout with no shared-service modifications.

No commands in this document have been executed on a VPS. The Docker image is a repository-only building block; its build has not been verified.
