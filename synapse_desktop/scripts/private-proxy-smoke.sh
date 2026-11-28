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
:5181 {
  bind 127.0.0.1
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
import { connect } from 'node:net'
import { randomBytes } from 'node:crypto'

async function probe(port, expected) {
  const status = await new Promise((resolve, reject) => {
    const socket = connect(port, '127.0.0.1')
    let data = ''
    socket.setTimeout(5000, () => socket.destroy(new Error('handshake timeout')))
    socket.once('connect', () => socket.write([
      'GET /api/bus HTTP/1.1',
      'Host: staging.example.test',
      'Origin: https://staging.example.test',
      'Cookie: ' + process.env.SYNAPSE_CI_COOKIE,
      'Connection: Upgrade',
      'Upgrade: websocket',
      'Sec-WebSocket-Version: 13',
      'Sec-WebSocket-Key: ' + randomBytes(16).toString('base64'),
      'X-Synapse-Proxy-Token: attacker',
      'X-Forwarded-For: 198.51.100.7, 203.0.113.8',
      '', '',
    ].join('\r\n')))
    socket.on('data', (chunk) => {
      data += chunk.toString('latin1')
      if (data.includes('\r\n')) {
        const match = /^HTTP\/1\.1 (\d{3}) /.exec(data)
        socket.destroy()
        match ? resolve(Number(match[1])) : reject(new Error('invalid handshake response'))
      }
    })
    socket.once('error', reject)
    socket.once('close', () => reject(new Error('connection closed before handshake')))
  })
  assert.equal(status, expected)
}
await probe(5180, 403)
await probe(5181, 101)
NODE
echo 'Disposable Caddy authenticated HTTP and WebSocket ingress; direct spoofing rejected.'
