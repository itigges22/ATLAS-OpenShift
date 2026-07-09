#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"
OUT_DIR="${2:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Copy deploy/openshift/openshift.env.example first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${ATLAS_NAMESPACE:?set ATLAS_NAMESPACE}"
: "${ATLAS_MODEL_PVC:?set ATLAS_MODEL_PVC}"
: "${ATLAS_MODEL_FILE:?set ATLAS_MODEL_FILE}"
: "${ATLAS_MAIN_MODEL:?set ATLAS_MAIN_MODEL}"
: "${ATLAS_MODELS_STORAGE:?set ATLAS_MODELS_STORAGE}"
: "${ATLAS_LLAMA_IMAGE:?set ATLAS_LLAMA_IMAGE}"
: "${ATLAS_LLAMA_IMAGE_TAG:?set ATLAS_LLAMA_IMAGE_TAG}"
: "${ATLAS_CUDA_ARCH:?set ATLAS_CUDA_ARCH}"
: "${ATLAS_KUEUE_QUEUE:=unreserved}"
: "${ATLAS_GPU_NODE_SELECTOR_KEY:?set ATLAS_GPU_NODE_SELECTOR_KEY}"
: "${ATLAS_GPU_NODE_SELECTOR_VALUE:?set ATLAS_GPU_NODE_SELECTOR_VALUE}"
: "${ATLAS_GPU_TOLERATION_KEY:?set ATLAS_GPU_TOLERATION_KEY}"
: "${ATLAS_GPU_TOLERATION_VALUE:?set ATLAS_GPU_TOLERATION_VALUE}"
: "${ATLAS_GPU_TOLERATION_EFFECT:=NoSchedule}"
export ATLAS_KUEUE_QUEUE
export ATLAS_GPU_NODE_SELECTOR_KEY
export ATLAS_GPU_NODE_SELECTOR_VALUE
export ATLAS_GPU_TOLERATION_KEY
export ATLAS_GPU_TOLERATION_VALUE
export ATLAS_GPU_TOLERATION_EFFECT

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/atlas-openshift-render.XXXXXX")"
fi
mkdir -p "$OUT_DIR"

for tmpl in "$ROOT"/deploy/openshift/templates/*.yaml; do
  envsubst < "$tmpl" > "$OUT_DIR/$(basename "$tmpl")"
done

echo "$OUT_DIR"
