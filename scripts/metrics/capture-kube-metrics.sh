#!/usr/bin/env bash
# Captures kubectl top nodes/pods and writes a JSON snapshot.
# Called twice per iteration (before/after) from the run scripts.
#
# Usage: bash scripts/metrics/capture-kube-metrics.sh <phase> <output-file>
# phase: "before" | "after"

set -euo pipefail

PHASE="${1:?Usage: capture-kube-metrics.sh <phase> <output-file>}"
OUTPUT="${2:?Usage: capture-kube-metrics.sh <phase> <output-file>}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Convert "kubectl top nodes --no-headers" lines to JSON entries.
# Input line format: <name>  <cpu>  <cpu%>  <memory>  <memory%>
nodes_to_json() {
  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    read -r name cpu cpu_pct mem mem_pct <<< "$line"
    $first || printf ','
    printf '{"name":"%s","cpu":"%s","cpuPercent":"%s","memory":"%s","memoryPercent":"%s"}' \
      "$name" "$cpu" "$cpu_pct" "$mem" "$mem_pct"
    first=false
  done
}

# Convert "kubectl top pods -A --no-headers" lines to JSON entries.
# Input line format: <namespace>  <name>  <cpu>  <memory>
pods_to_json() {
  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    read -r ns name cpu mem <<< "$line"
    $first || printf ','
    printf '{"namespace":"%s","name":"%s","cpu":"%s","memory":"%s"}' \
      "$ns" "$name" "$cpu" "$mem"
    first=false
  done
}

kubectl_top_with_retry() {
  local args=("$@")
  local out=""
  for attempt in 1 2 3; do
    out=$(kubectl top "${args[@]}" --no-headers 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return; }
    [ "$attempt" -lt 3 ] && echo "  kubectl top ${args[*]}: empty (attempt $attempt/3), retrying in 15s..." >&2 && sleep 15
  done
  echo "  WARNING: kubectl top ${args[*]} returned empty after 3 attempts" >&2
}

NODES_OUT=$(kubectl_top_with_retry nodes)
PODS_OUT=$(kubectl_top_with_retry pods -A)

NODES_JSON=$(echo "$NODES_OUT" | nodes_to_json)
PODS_JSON=$(echo "$PODS_OUT" | pods_to_json)

cat > "$OUTPUT" << ENDJSON
{
  "phase": "$PHASE",
  "capturedAt": "$TIMESTAMP",
  "nodes": [$NODES_JSON],
  "pods": [$PODS_JSON]
}
ENDJSON

echo "  Kubernetes metrics ($PHASE) → $OUTPUT"
