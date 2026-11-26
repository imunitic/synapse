# Private staging foundation (not deployment authorization)

The repository contains `synapse_desktop/Dockerfile.private-host`, a Node 24 image for the existing **local-mode** Node host. From the repository root, its intended build command is:

```sh
docker build -f synapse_desktop/Dockerfile.private-host -t synapse-private-host:dev .
```

This is **not yet a deployable PWA stack**. The image has no published port. The repository has a detached authenticated gateway dispatcher, login page, session store and protected Vite asset loader, and an opt-in gateway entrypoint and a private staging Compose topology, but no provisioned runtime configuration or HTTPS termination. By default the Node process binds `127.0.0.1` in its own network namespace. It can now opt in to an explicit RFC1918 IPv4 bind address with `SYNAPSE_DESKTOP_PRIVATE_BIND_ADDRESS` and `SYNAPSE_DESKTOP_TOKEN`; the gateway can route to literal RFC1918 IPv4 backend URLs. This does **not** provision or enforce private Docker networks, and must not be deployed before network isolation is tested. Never map its port to the public interface or enable `SYNAPSE_DESKTOP_HOST_MODE=remote`.

## Architecture decision: isolated backend containers (2026-11-24)

**Chosen direction:** one authenticated HTTPS-facing gateway routes each user to a separately provisioned Node backend container through **private container networking**, rather than sharing a network namespace between all users. The repository implements a candidate topology in `compose.private-staging.yml`; runtime isolation still requires verification.

- Each user gets a distinct backend container, writable home/workspace volume, backend token, and agent/Git authentication context. No user shares a terminal or writable workspace with another user.
- Only the gateway is reachable through the authorized HTTPS reverse proxy. Backend services must not publish host/public ports. Gateway routing must derive the backend from the authenticated server-side user identity, never a client-supplied container address or token.
- The Node backend and gateway now support **opt-in literal RFC1918 IPv4 addresses**, retaining loopback defaults and backend token/Origin checks. The staging Compose file supplies separate ingress and per-user networks; verify cross-user isolation in the intended runtime. Do not enable `SYNAPSE_DESKTOP_HOST_MODE=remote`.
- Private networking alone does not guarantee user isolation. Explicitly restrict east-west traffic, container privileges, mounted paths, and access to Docker control sockets; verify that user A cannot connect to user B's backend even with a known address.
- Adding user C should be provisioning/configuration (new isolated backend, volume, secret and authenticated routing entry), not an application code change. A container per user is the scaling unit, subject to VPS resource limits.
- Before any deployment: prove gateway-to-container WebSocket/PTY flow, session revocation, two-user cross-access rejection, and clean container restart in automated tests. Keep secrets out of the repository and CI logs. Do not deploy or alter the VPS without fresh authorization.

Before an authorized private staging deployment:

1. Build the frontend with `npm run build` in `synapse_desktop`. The opt-in gateway entrypoint is `npm run gateway:private` and requires `SYNAPSE_PRIVATE_GATEWAY_CONFIG` pointing to an operator-owned JSON file (never commit the file). It loads the Vite build from `buildDirectory` and uses existing login/logout and session issuance; do not build a second authentication stack. The required JSON fields are `port` (gateway listening port), `publicHost` (external HTTPS host and optional port), `publicOrigin` (matching exact HTTPS origin), `buildDirectory`, `accounts` (username, userId, scrypt passwordHash) and `hosts` (userId, literal loopback or RFC1918 IPv4 backend URL, backendToken, backendOrigin). No accounts or backend tokens are supplied by the repository. HTTPS termination and correct Host/Origin forwarding are required for a real browser session; this command alone is not a browser demo. The default listener is loopback-only. Dedicated container ingress requires `SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND=1`, an explicit `SYNAPSE_PRIVATE_GATEWAY_BIND_ADDRESS`, and a nonempty `trustedProxyAddresses` array of literal proxy IPs in the JSON configuration. Startup rejects missing or invalid trusted proxy addresses in this mode. Configure the HTTPS proxy to replace client-supplied forwarding headers with one verified client IP; determine the actual TCP peer address seen by the gateway rather than copying a fixture address.
2. Review and verify `synapse_desktop/compose.private-staging.yml` and `synapse_desktop/scripts/private-staging-smoke.sh`. The candidate topology binds the gateway to its dedicated ingress interface, publishes gateway port 5180 only on host loopback, and gives each backend a separate private network and home volume. Backends publish no host ports. Two gateway users must never share the same Node host/terminal namespace.
3. Supply a unique backend token per private host at runtime via secret injection, not Docker build args, committed files or browser headers. Set `SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN` to the gateway's exact private Origin.
4. Keep the authenticated gateway → Node bus → real PTY smoke test green, and verify reconnect/revocation and two-user separation in CI. The CI Docker image build and native PTY module import have passed on Linux; continue checking container startup and actual gateway-to-container PTY behavior.
5. Only after separate authorization, select a private staging hostname and TLS/auth approach, review VPS resource isolation with ReadBack, and perform a reversible staging rollout with no shared-service modifications.

No commands in this document have been executed on a VPS. Repository CI and smoke tests do not establish that a particular VPS proxy, network, or secret configuration is safe.
