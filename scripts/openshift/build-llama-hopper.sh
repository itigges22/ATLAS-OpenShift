#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"

RENDERED="$("$ROOT/scripts/openshift/render.sh" "$ENV_FILE")"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "Applying Hopper llama BuildConfig in namespace ${ATLAS_NAMESPACE}..."
oc apply -n "$ATLAS_NAMESPACE" -f "$RENDERED/00-build-llama-hopper.yaml"

echo "Starting binary build from inference/ with CUDA_ARCH=${ATLAS_CUDA_ARCH}..."
oc start-build "$ATLAS_LLAMA_IMAGE" \
  -n "$ATLAS_NAMESPACE" \
  --from-dir="$ROOT/inference" \
  --follow \
  --wait

echo "Built image stream tag: ${ATLAS_LLAMA_IMAGE}:${ATLAS_LLAMA_IMAGE_TAG}"
