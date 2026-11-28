#!/usr/bin/env bash
set -euo pipefail
: "${SYNAPSE_CI_COOKIE:?fixture session required}"
config=$(mktemp)
name=synapse-private-ci-caddy
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -f "$config"
}
trap cleanup EXIT
cat > "$config" <<'CADDY'
{
  admin off
  auto_https off
}
http://127.0.0.1:5181 {
  reverse_proxy 127.0.0.1:5180 {
    header_up Host staging.example.test
    header_up X-Synapse-Proxy-Token aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    header_up X-Forwarded-For {http.request.remote.host}
  }
}
CADDY
chmod 644 "$config"
docker run -d --name "$name" --network host \
  --mount "type=bind,src=$config,dst=/etc/caddy/Caddyfile,readonly" \
  caddy:2-alpine >/dev/null
ready=0
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:5181/login >/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]]
# Both attacker-controlled headers must be replaced, not appended or trusted.
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Origin: https://staging.example.test' \
  -H 'Content-Type: application/json' \
  -H 'X-Synapse-Proxy-Token: attacker' \
  -H 'X-Forwarded-For: 198.51.100.7, 203.0.113.8' \
  --data '{"username":"fixture-a","password":"ci-fixture-password-a"}' \
  http://127.0.0.1:5181/auth/session)" == 200 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Host: staging.example.test' -H 'X-Forwarded-For: 198.51.100.7' \
  http://127.0.0.1:5180/login)" == 403 ]]
node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { WebSocket } from 'ws'

async function probe(port, expected) {
  await new Promise((resolve, reject) => {
    const ws = new WebSocket('ws://127.0.0.1:' + port + '/api/bus', {
      headers: {
        Host: 'staging.example.test',
        Origin: 'https://staging.example.test',
        Cookie: process.env.SYNAPSE_CI_COOKIE,
        'X-Synapse-Proxy-Token': 'attacker',
        'X-Forwarded-For': '198.51.100.7, 203.0.113.8',
      },
      handshakeTimeout: 5000,
    })
    ws.once('open', () => {
      ws.terminate()
      expected === 101 ? resolve() : reject(new Error('unexpected upgrade'))
    })
    ws.once('unexpected-response', (_request, response) => {
      response.resume()
      ws.terminate()
      try { assert.equal(response.statusCode, expected); resolve() } catch (error) { reject(error) }
    })
    ws.once('error', (error) => { if (expected === 101) reject(error) })
  })
}
await probe(5180, 403)
await probe(5181, 101)
NODE
echo 'Disposable Caddy authenticated HTTP and WebSocket ingress; direct spoofing rejected.'
