#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"
TASKS="${2:-10}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${ATLAS_NAMESPACE:?set ATLAS_NAMESPACE}"
: "${ATLAS_BENCH_MODELS:?set ATLAS_BENCH_MODELS}"

patch_model() {
  local file="$1"
  local name="$2"

  echo "Patching active model to ${name} (${file})..."
  oc set env deploy/atlas-llama-server -n "$ATLAS_NAMESPACE" \
    MODEL_PATH="/models/${file}" \
    ATLAS_MODEL_NAME="${name}"
  oc set env deploy/atlas-geometric-lens -n "$ATLAS_NAMESPACE" \
    ATLAS_MODEL_NAME="${name}"
  oc set env deploy/atlas-v3-service -n "$ATLAS_NAMESPACE" \
    ATLAS_MODEL_NAME="${name}"
  oc set env deploy/atlas-proxy -n "$ATLAS_NAMESPACE" \
    ATLAS_MODEL_NAME="${name}"

  oc rollout restart deploy/atlas-llama-server -n "$ATLAS_NAMESPACE"
  oc rollout restart deploy/atlas-geometric-lens -n "$ATLAS_NAMESPACE"
  oc rollout restart deploy/atlas-v3-service -n "$ATLAS_NAMESPACE"
  oc rollout restart deploy/atlas-proxy -n "$ATLAS_NAMESPACE"

  oc rollout status deploy/atlas-llama-server -n "$ATLAS_NAMESPACE" --timeout=30m
  oc rollout status deploy/atlas-geometric-lens -n "$ATLAS_NAMESPACE" --timeout=10m || true
  oc rollout status deploy/atlas-v3-service -n "$ATLAS_NAMESPACE" --timeout=10m || true
  oc rollout status deploy/atlas-proxy -n "$ATLAS_NAMESPACE" --timeout=10m || true
}

IFS=';' read -r -a MODELS <<< "$ATLAS_BENCH_MODELS"
for entry in "${MODELS[@]}"; do
  [[ -z "$entry" ]] && continue
  IFS='|' read -r label model_file model_name notes <<< "$entry"
  if [[ -z "${label:-}" || -z "${model_file:-}" || -z "${model_name:-}" ]]; then
    echo "Bad ATLAS_BENCH_MODELS entry: $entry" >&2
    exit 1
  fi

  echo
  echo "============================================================"
  echo "Model: ${label}"
  echo "File: ${model_file}"
  echo "Name: ${model_name}"
  echo "Notes: ${notes:-}"
  echo "============================================================"

  patch_model "$model_file" "$model_name"
  "$ROOT/scripts/openshift/run-benchmark-pair.sh" "$label" "$TASKS"
done
