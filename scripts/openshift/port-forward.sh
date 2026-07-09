#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${ATLAS_NAMESPACE:?set ATLAS_NAMESPACE}"
: "${ATLAS_LOCAL_LLAMA_PORT:=18080}"
: "${ATLAS_LOCAL_LENS_PORT:=18099}"
: "${ATLAS_LOCAL_PROXY_PORT:=18090}"

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Forwarding cluster services to localhost:"
echo "  llama: http://127.0.0.1:${ATLAS_LOCAL_LLAMA_PORT}"
echo "  lens:  http://127.0.0.1:${ATLAS_LOCAL_LENS_PORT}"
echo "  proxy: http://127.0.0.1:${ATLAS_LOCAL_PROXY_PORT}"

oc port-forward -n "$ATLAS_NAMESPACE" svc/atlas-llama-server "${ATLAS_LOCAL_LLAMA_PORT}:8080" &
oc port-forward -n "$ATLAS_NAMESPACE" svc/atlas-geometric-lens "${ATLAS_LOCAL_LENS_PORT}:8099" &
oc port-forward -n "$ATLAS_NAMESPACE" svc/atlas-proxy "${ATLAS_LOCAL_PROXY_PORT}:8090" &

wait
