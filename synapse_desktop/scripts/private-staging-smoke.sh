#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=$(mktemp)
export SYNAPSE_GATEWAY_CONFIG="$config"
export SYNAPSE_BACKEND_A_TOKEN=ci-fixture-a
export SYNAPSE_BACKEND_B_TOKEN=ci-fixture-b
# Public CI-only fixture, never a deployment credential.
proxy_token=$(printf 'a%.0s' {1..64})
proxy_curl() { curl -H "X-Synapse-Proxy-Token: $proxy_token" "$@"; }
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
  proxyToken: 'a'.repeat(64),
  accounts,
  hosts,
}))
JS
chmod 644 "$config"
"${compose[@]}" config --quiet
"${compose[@]}" up -d --build
# Verify effective users and distinct writable homes in the running containers.
for service in gateway backend_a backend_b; do
  [[ "$("${compose[@]}" exec -T "$service" id -u)" != 0 ]]
  "${compose[@]}" exec -T "$service" node -e '
    const status = require("node:fs").readFileSync("/proc/self/status", "utf8")
    const field = (name) => status.match(new RegExp("^" + name + ":\\s*(\\S+)", "m"))?.[1]
    if (field("NoNewPrivs") !== "1" ||
        !["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"].every((name) => /^0+$/.test(field(name) ?? ""))) {
      console.error("container privilege restrictions are not effective")
      process.exit(1)
    }
  '
done
for backend in backend_a backend_b; do
  "${compose[@]}" exec -T "$backend" sh -ec 'test ! -e /home/node/.synapse-ci-isolation'
done
"${compose[@]}" exec -T backend_a sh -ec 'printf a > /home/node/.synapse-ci-isolation'
"${compose[@]}" exec -T backend_b sh -ec 'test ! -e /home/node/.synapse-ci-isolation; printf b > /home/node/.synapse-ci-isolation'
[[ "$("${compose[@]}" exec -T backend_a cat /home/node/.synapse-ci-isolation)" == a ]]
[[ "$("${compose[@]}" exec -T backend_b cat /home/node/.synapse-ci-isolation)" == b ]]
for backend in backend_a backend_b; do
  "${compose[@]}" exec -T "$backend" rm /home/node/.synapse-ci-isolation
done
echo 'Containers run non-root; backend home writes remain isolated.'
# Exercise the installed development tools as the actual backend user.
"${compose[@]}" exec -T backend_a sh -ec '
  git --version >/dev/null
  codex --version >/dev/null
  synapse --help >/dev/null
  synapse-pipeline --help >/dev/null
  work=$(mktemp -d)
  trap '\''rm -rf "$work"'\'' EXIT
  git -C "$work" init -q
  printf "before\\n" > "$work/fixture.txt"
  git -C "$work" add fixture.txt
  printf "after\\n" > "$work/fixture.txt"
  git -C "$work" diff --exit-code -- fixture.txt >/dev/null && exit 1
  git -C "$work" diff -- fixture.txt | grep -q "^+after$"
'
echo 'Backend development tools execute and Git produces a task diff.'
"${compose[@]}" exec -T backend_a node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { planSession } from './server/inject.ts'

const home = await mkdtemp(join(tmpdir(), 'synapse-session-'))
try {
  const plan = await planSession('Codex', {
    env: process.env,
    home,
    dataDir: join(home, 'sessions'),
  })
  assert.equal(plan.command, 'codex')
  assert.equal(plan.loaded, true, plan.note)
  assert.ok(plan.env.CODEX_HOME)
  assert.ok(plan.env.SYNAPSE_CONTENT_ROOT)
  const hooks = await readFile(join(plan.env.CODEX_HOME, 'hooks.json'), 'utf8')
  assert.match(hooks, /synapse-hook/)
  assert.ok((await readdir(join(plan.env.CODEX_HOME, 'skills'))).length > 0)
} finally {
  await rm(home, { recursive: true, force: true })
}
NODE
echo 'Codex session loads Synapse skills and hooks.'
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
  if proxy_curl -fsS -H 'Host: staging.example.test' http://127.0.0.1:5180/login >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]]
# A forged forwarded identity without the proxy credential must be rejected.
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Host: staging.example.test' -H 'X-Forwarded-For: 198.51.100.7' \
  http://127.0.0.1:5180/login)" == 403 ]]
# The loopback-published connection must arrive from the configured trusted peer.
# Missing or ambiguous forwarded identities must fail closed; a single fixture
# identity must permit the real composed login path.
login_status() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Host: staging.example.test' \
    -H 'Origin: https://staging.example.test' \
    -H 'Content-Type: application/json' \
    "$@" \
    --data '{"username":"fixture-a","password":"ci-fixture-password-a"}' \
    http://127.0.0.1:5180/auth/session
}
[[ "$(login_status)" == 503 ]]
[[ "$(login_status -H 'X-Forwarded-For: 198.51.100.7, 203.0.113.8')" == 503 ]]
[[ "$(login_status -H 'X-Forwarded-For: 198.51.100.7')" == 200 ]]
echo 'Composed login accepts only a single forwarded identity from the fixture proxy peer.'

# Capture only the fixture cookie in memory; replay it after logout to verify
# server-side revocation rather than merely browser-side cookie clearing.
cookie=$(proxy_curl -fsS -D - -o /dev/null \
  -H 'Host: staging.example.test' \
  -H 'Origin: https://staging.example.test' \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 198.51.100.7' \
  --data '{"username":"fixture-a","password":"ci-fixture-password-a"}' \
  http://127.0.0.1:5180/auth/session |
  awk '
    tolower($1) == "set-cookie:" {
      line = tolower($0)
      if (line !~ /;[[:space:]]*secure([;[:space:]]|$)/ ||
          line !~ /;[[:space:]]*httponly([;[:space:]]|$)/ ||
          line !~ /;[[:space:]]*samesite=(strict|lax)([;[:space:]]|$)/ ||
          line !~ /;[[:space:]]*path=\/([;[:space:]]|$)/ ||
          line ~ /;[[:space:]]*domain=/) exit 1
      sub(/;.*/, "", $2)
      print $2
      exit
    }
  ')
[[ -n "$cookie" ]]
session_status() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Host: staging.example.test' \
    -H 'Origin: https://staging.example.test' \
    -H "Cookie: $cookie" "$@"
}
[[ "$(session_status http://127.0.0.1:5180/auth/me)" == 200 ]]
for origin in '' 'https://attacker.example.test'; do
  [[ "$(proxy_curl -sS -o /dev/null -w '%{http_code}' \
    -X POST -H 'Host: staging.example.test' -H "Origin: $origin" \
    -H "Cookie: $cookie" http://127.0.0.1:5180/auth/logout)" == 403 ]]
  [[ "$(session_status http://127.0.0.1:5180/auth/me)" == 200 ]]
done
[[ "$(proxy_curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Host: attacker.example.test' -H "Cookie: $cookie" \
  http://127.0.0.1:5180/auth/me)" == 403 ]]
[[ "$(session_status -X POST http://127.0.0.1:5180/auth/logout)" == 200 ]]
[[ "$(session_status http://127.0.0.1:5180/auth/me)" == 401 ]]
unset cookie
echo 'Composed session authenticates and rejects the revoked cookie after logout.'


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
