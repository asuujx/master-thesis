#!/usr/bin/env bash
# Runs 5 curl probes from the CI runner to the app LoadBalancer and writes
# results/network_rtt.json. Called by each pipeline before npm run e2e so
# the runner-to-cluster network path is measured independently of test logic.
#
# Usage: bash scripts/metrics/measure-rtt.sh <base-url>

set -euo pipefail

BASE_URL="${1:?Usage: measure-rtt.sh <base-url>}"
PROBES=5

echo "==> Measuring network RTT (${PROBES} probes → $BASE_URL)..."
mkdir -p results

{
  echo '['
  for probe in $(seq 1 $PROBES); do
    TIMING=$(curl -o /dev/null -s \
      -w '%{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total} %{http_code}' \
      "$BASE_URL" || echo '0 0 0 0 000')
    read -r dns tcp ttfb total code <<< "$TIMING"
    [ "$probe" -lt "$PROBES" ] && COMMA=',' || COMMA=''
    printf '  {"probe":%s,"dnsSeconds":%s,"tcpSeconds":%s,"ttfbSeconds":%s,"totalSeconds":%s,"httpCode":"%s"}%s\n' \
      "$probe" "$dns" "$tcp" "$ttfb" "$total" "$code" "$COMMA"
  done
  echo ']'
} > results/network_rtt.json

echo "  Written to results/network_rtt.json"
