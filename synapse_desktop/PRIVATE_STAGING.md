# Private staging foundation (not deployment authorization)

The repository contains `synapse_desktop/Dockerfile.private-host`, a Node 24 image for the existing **local-mode** Node host. From the repository root, its intended build command is:

```sh
docker build -f synapse_desktop/Dockerfile.private-host -t synapse-private-host:dev .
```

This is **not yet a deployable PWA stack**. The image has no published port. The repository has a detached authenticated gateway dispatcher, login page, session store and protected Vite asset loader, but no operator-configured runnable gateway process or complete container topology. The Node process binds `127.0.0.1` in its own network namespace and requires a separately provisioned private gateway with a compatible namespace and explicit backend token/origin. Never map its port to the public interface or enable `SYNAPSE_DESKTOP_HOST_MODE=remote`.

Before an authorized private staging deployment:

1. Wire the existing `server/gateway-private-entry.ts` dispatcher into a runnable private gateway process with operator-provided account hashes, `publicHost`/`publicOrigin`, protected production asset manifest and per-user backend mapping. Login/logout and session issue/revoke already exist in the dispatcher; do not build a second authentication stack. Keep the listener loopback-only until an explicitly authorized HTTPS reverse-proxy deployment.
2. Design a reproducible per-user network namespace and persistent workspace volume. Two gateway users must never share the same Node host/terminal namespace.
3. Supply a unique backend token per private host at runtime via secret injection, not Docker build args, committed files or browser headers. Set `SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN` to the gateway's exact private Origin.
4. Keep the authenticated gateway → Node bus → real PTY smoke test green, and verify reconnect/revocation and two-user separation in CI. Confirm the Docker image actually builds and that the Node 24 PTY native dependency loads on the target architecture; this has not yet been demonstrated.
5. Only after separate authorization, select a private staging hostname and TLS/auth approach, review VPS resource isolation with ReadBack, and perform a reversible staging rollout with no shared-service modifications.

No commands in this document have been executed on a VPS. The Docker image is a repository-only building block; its build has not been verified.
