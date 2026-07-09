#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-smoke}"
TASKS="${2:-10}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

export LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:${ATLAS_LOCAL_LLAMA_PORT:-18080}}"
export RAG_API_URL="${RAG_API_URL:-http://127.0.0.1:${ATLAS_LOCAL_LENS_PORT:-18099}}"
export ATLAS_LLM_PARALLEL="${ATLAS_LLM_PARALLEL:-1}"
export ATLAS_PARALLEL_TASKS="${ATLAS_PARALLEL_TASKS:-1}"
BENCH_ARGS=()
if [[ -n "${ATLAS_BENCH_MAX_TOKENS:-}" ]]; then
  BENCH_ARGS+=(--max-tokens "$ATLAS_BENCH_MAX_TOKENS")
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE_RUN_ID="${LABEL}_baseline_${STAMP}"
ROUTED_RUN_ID="${LABEL}_routed_${STAMP}"

echo "============================================================"
echo "ATLAS benchmark pair: ${LABEL}"
echo "Tasks: ${TASKS}"
echo "LLAMA_URL=${LLAMA_URL}"
echo "RAG_API_URL=${RAG_API_URL}"
echo "============================================================"

python3 -m benchmark.v3_runner \
  --run-id "$BASE_RUN_ID" \
  --baseline \
  --max-tasks "$TASKS" \
  "${BENCH_ARGS[@]}"

python3 -m benchmark.v3_runner \
  --run-id "$ROUTED_RUN_ID" \
  --selection-strategy lens \
  --max-tasks "$TASKS" \
  "${BENCH_ARGS[@]}"

echo
echo "Results:"
echo "  benchmark/results/${BASE_RUN_ID}"
echo "  benchmark/results/${ROUTED_RUN_ID}"
