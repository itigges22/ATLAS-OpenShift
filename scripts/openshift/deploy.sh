#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"

RENDERED="$("$ROOT/scripts/openshift/render.sh" "$ENV_FILE")"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "Deploying ATLAS OpenShift resources to namespace ${ATLAS_NAMESPACE}..."
oc apply -n "$ATLAS_NAMESPACE" -f "$RENDERED/10-storage.yaml"
oc apply -n "$ATLAS_NAMESPACE" -f "$RENDERED/20-runtime.yaml"

echo "Waiting for non-llama services to become available..."
oc rollout status deploy/atlas-geometric-lens -n "$ATLAS_NAMESPACE" --timeout=10m || true
oc rollout status deploy/atlas-sandbox -n "$ATLAS_NAMESPACE" --timeout=10m || true
oc rollout status deploy/atlas-v3-service -n "$ATLAS_NAMESPACE" --timeout=10m || true
oc rollout status deploy/atlas-proxy -n "$ATLAS_NAMESPACE" --timeout=10m || true

echo "llama-server can take longer while loading the model:"
oc rollout status deploy/atlas-llama-server -n "$ATLAS_NAMESPACE" --timeout=20m || true

echo
oc get pods,svc,route -n "$ATLAS_NAMESPACE" -l app.kubernetes.io/part-of=atlas-openshift
