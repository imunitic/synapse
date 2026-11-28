# Private PWA staging gates (not a deployment procedure)

This document tracks the minimum conditions for a **private** remote Synapse proof of concept. Nothing here authorizes changing a VPS, exposing a port, enabling remote mode, or provisioning real credentials. Keep PR #30 draft.

## What exists in the repository

- `server/index.ts` runs the real Node bus and controlled PTYs, but binds **127.0.0.1** and rejects `SYNAPSE_DESKTOP_HOST_MODE=remote`.
- `server/gateway-private-entry.ts` composes the password/session HTTP handlers, protected frontend assets and authenticated WebSocket routing. It attaches to an operator-supplied server; it does **not** listen.
- `server/gateway-real-pty.test.ts` exercises a loopback gateway, authenticated WebSocket connection, real Node bus and real shell PTY without starting an agent.
- `npm run check` includes TypeScript, build, gateway asset validation, lint, Prettier and unit/integration tests. CI is authoritative; do not infer a pass from local checks.

## Required implementation order

1. **Runnable local-only private gateway:** provide an explicit CLI entrypoint that loads the built asset manifest, accounts and user-to-backend mapping, validates all configuration before listening, and binds loopback only. No default password, secret logging or public bind.
2. **Real backend process lifecycle:** start the existing Node host as a separate process with a gateway-only backend token and dedicated Origin. Verify startup, readiness, graceful shutdown, PTY execution and failure propagation. Preserve the local desktop entrypoint and fail-closed remote-mode guard.
3. **End-to-end browser smoke:** test login, protected navigation/assets, authenticated bus connection, xterm terminal input/output, logout and reconnect. Use disposable fixture accounts and temporary directories.
4. **Reproducible staging packaging:** pin a Node runtime, build assets and backend in Docker, run as non-root, bind internal services to loopback/private networking, and provide a health/readiness check. Test the container with disposable data.
5. **Multi-user boundary:** validate that two fixture accounts cannot route to each other's backend or PTY, even after logout/reconnect. Do not treat a shared host process as isolation.
6. **Agent and Git workflows:** only after the above, verify agent CLI login and repository access with non-sensitive fixtures. Do not collect or store real credentials in CI.

## Operator handoff before any staging deployment

Obtain explicit authorization for the target host and staging hostname; inventory existing ports, Docker networks, volumes, reverse proxy routes and resource limits; confirm ReadBack's containers and routes are untouched. Decide where secrets are provisioned and rotated, how users are isolated, and how to revert staging without affecting ReadBack. Require a reviewed, passing CI run for the exact commit to be deployed. The first deployment should remain private and reversible, with no production traffic.

**Not yet demonstrated:** a runnable gateway entrypoint, container deployment, browser-to-real-PTY full path, multi-user isolation, or agent/Git login. Passing the current gateway and PTY component tests does not establish any of those.
