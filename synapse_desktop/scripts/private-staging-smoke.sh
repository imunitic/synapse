#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=$(mktemp)
export SYNAPSE_GATEWAY_CONFIG="$config"
export SYNAPSE_BACKEND_A_TOKEN=ci-fixture-a
export SYNAPSE_BACKEND_B_TOKEN=ci-fixture-b
compose=(docker compose -p synapse-private-ci -f compose.private-staging.yml)
cleanup() {
  "${compose[@]}" logs --tail=50 || true
  "${compose[@]}" down -v --remove-orphans || true
  rm -f "$config"
}
trap cleanup EXIT
node --input-type=module > "$config" <<'JS'
import { hashGatewayPassword } from './server/gateway-password-verifier.ts'
const accounts = []
const hosts = []
for (const [id, address, token] of [
  ['a', '172.29.101.2', process.env.SYNAPSE_BACKEND_A_TOKEN],
  ['b', '172.29.102.2', process.env.SYNAPSE_BACKEND_B_TOKEN],
]) {
  accounts.push({
    username: 'fixture-' + id,
    userId: id,
    passwordHash: await hashGatewayPassword('ci-fixture-password-' + id),
  })
  hosts.push({
    userId: id,
    backend: 'http://' + address + ':5174',
    backendToken: token,
    backendOrigin: 'http://gateway.internal',
  })
}
console.log(JSON.stringify({
  port: 5180,
  publicHost: 'staging.example.test',
  publicOrigin: 'https://staging.example.test',
  buildDirectory: '/opt/synapse/dist',
  trustedProxyAddresses: ['172.29.103.1'],
  accounts,
  hosts,
}))
JS
chmod 644 "$config"
"${compose[@]}" config --quiet
"${compose[@]}" up -d --build
for backend in backend_a backend_b; do
  address=172.29.101.2
  if [[ "$backend" == backend_b ]]; then address=172.29.102.2; fi
  ready=0
  for attempt in $(seq 1 30); do
    if "${compose[@]}" exec -T gateway node -e "fetch('http://$address:5174').then(r => process.exit(r.status === 404 ? 0 : 1)).catch(() => process.exit(1))"; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" == 1 ]]
done
# Fail on any successful TCP connection or unexpected probe error.
assert_tcp_blocked() {
  local backend=$1 address=$2 port=$3
  "${compose[@]}" exec -T "$backend" node -e '
    const socket = require("node:net").connect(Number(process.argv[2]), process.argv[1])
    socket.once("connect", () => process.exit(1))
    socket.once("error", (error) =>
      process.exit(["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "ETIMEDOUT"].includes(error.code) ? 0 : 1),
    )
    socket.setTimeout(3000, () => { socket.destroy(); process.exit(0) })
  ' "$address" "$port"
}

for pair in 'backend_a 172.29.102.2' 'backend_b 172.29.101.2'; do
  read -r backend address <<< "$pair"
  assert_tcp_blocked "$backend" "$address" 5174
done
echo 'Gateway can reach both backends; cross-backend TCP connections blocked.'

# Verify the published listener works and neither backend can reach it directly.
ready=0
for attempt in $(seq 1 30); do
  if curl -fsS -H 'Host: staging.example.test' http://127.0.0.1:5180/login >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]]
for backend in backend_a backend_b; do
  for address in 172.29.101.3 172.29.102.3 172.29.103.2; do
    assert_tcp_blocked "$backend" "$address" 5180
  done
done
echo 'Gateway ingress reachable from host loopback, not from backend containers.'

# Exercise the maximum concurrent scrypt workload inside the constrained gateway.
"${compose[@]}" exec -T gateway node --input-type=module <<'JS'
import { readFile } from 'node:fs/promises'
import { createPasswordVerifier } from './server/gateway-password-verifier.ts'
const config = JSON.parse(await readFile('/run/secrets/gateway.json', 'utf8'))
const verify = createPasswordVerifier(config.accounts)
const results = await Promise.all([
  verify('fixture-a', 'ci-fixture-password-a'),
  verify('fixture-b', 'ci-fixture-password-b'),
])
if (results[0] !== 'a' || results[1] !== 'b') process.exitCode = 1
JS
echo 'Concurrent fixture password checks completed within the gateway container limit.'
