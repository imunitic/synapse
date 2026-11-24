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
cat > "$config" <<'JSON'
{
  "port": 5180,
  "publicHost": "staging.example.test",
  "publicOrigin": "https://staging.example.test",
  "buildDirectory": "/opt/synapse/dist",
  "accounts": [],
  "hosts": []
}
JSON
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
# A successful TCP connection to the other user's backend is a failure.
for pair in 'backend_a 172.29.102.2' 'backend_b 172.29.101.2'; do
  read -r backend address <<< "$pair"
  "${compose[@]}" exec -T "$backend" node -e "fetch('http://$address:5174', {signal: AbortSignal.timeout(3000)}).then(() => process.exit(1)).catch(() => process.exit(0))"
done
echo 'Gateway can reach both backends; cross-backend HTTP connections blocked.'
