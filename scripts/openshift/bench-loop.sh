#!/bin/sh
# Self-healing driver for a baseline+routed benchmark pair, run INSIDE the
# atlas-bench pod (nohup sh bench-loop.sh <label> &). Survives GPU
# preemptions: purges error checkpoints, waits for llama+lens health,
# resumes, repeats until each arm has all its tasks with zero errors.
#
# TRIPWIRE: for lens-selection arms, after the first $TRIP_N checkpoints
# the loop audits candidate_energies; if every score is the 0.0 exception
# sentinel, it ABORTS the run instead of silently completing a no-lens
# control arm (this exact failure burned the 2026-07-10 routed run: lens
# /ready was green but its embedding calls starved behind saturated
# llama slots, so 138/146 tasks recorded all-zero energies).
LABEL="${1:?usage: bench-loop.sh <label> [total_tasks]}"
TOTAL="${2:-175}"
TRIP_N=8

cd /bench/ATLAS
export PYTHONPATH=/bench/ATLAS ATLAS_LCB_RELEASE="${ATLAS_LCB_RELEASE:-release_v6only}" \
       ATLAS_LLM_PARALLEL=1 ATLAS_PARALLEL_TASKS="${ATLAS_PARALLEL_TASKS:-4}"
BASE="${LABEL}_baseline"
ROUTED="${LABEL}_routed"

purge() {
  python - "$1" <<'EOF'
import json, glob, os, sys
n = 0
for f in glob.glob(f"/bench/ATLAS/benchmark/results/{sys.argv[1]}/v3_lcb/per_task/*.json"):
    if json.load(open(f)).get("phase_solved") == "error":
        os.remove(f); n += 1
print(f"purged {n} error checkpoints from {sys.argv[1]}")
EOF
}

count_done() { ls "benchmark/results/$1/v3_lcb/per_task" 2>/dev/null | wc -l; }

# 0 = healthy real scores; 1 = ALL sentinel (lens dead) -> abort
energies_ok() {
  python - "$1" "$TRIP_N" <<'EOF'
import json, glob, sys
files = glob.glob(f"/bench/ATLAS/benchmark/results/{sys.argv[1]}/v3_lcb/per_task/*.json")
if len(files) < int(sys.argv[2]):
    sys.exit(0)  # not enough data yet — keep going
tot = real = 0
for f in files:
    for c in (json.load(open(f)).get("telemetry", {}).get("candidate_energies") or []):
        tot += 1
        real += c.get("energy", 0.0) > 0.001
if tot and real == 0:
    print(f"TRIPWIRE: {tot} candidate energies, ALL 0.0 sentinels — lens scoring is dead")
    sys.exit(1)
print(f"energy audit: {real}/{tot} real scores")
sys.exit(0)
EOF
}

wait_healthy() {
  while true; do
    python -c "
import urllib.request
urllib.request.urlopen('http://atlas-llama-server:8080/health', timeout=5)
urllib.request.urlopen('http://atlas-geometric-lens:8099/ready', timeout=5)
" 2>/dev/null && return 0
    echo "$(date -u +%FT%TZ) waiting for llama+lens…"
    sleep 60
  done
}

run_arm() {  # $1 = run id, $2 = runner args, $3 = tripwire yes/no
  while true; do
    purge "$1"
    done_n=$(count_done "$1")
    if [ "$done_n" -ge "$TOTAL" ]; then
      echo "$(date -u +%FT%TZ) $1 complete ($done_n/$TOTAL)"
      return 0
    fi
    wait_healthy
    echo "$(date -u +%FT%TZ) launching $1 ($done_n/$TOTAL done)"
    python -u -m benchmark.v3_runner --run-id "$1" $2 &
    RUNNER=$!
    if [ "$3" = "yes" ]; then
      while kill -0 $RUNNER 2>/dev/null; do
        sleep 120
        if ! energies_ok "$1"; then
          kill $RUNNER
          echo "$(date -u +%FT%TZ) ABORTED $1 — lens sentinel tripwire. Fix lens scoring, then rerun."
          return 1
        fi
      done
    fi
    wait $RUNNER || true
  done
}

echo "$(date -u +%FT%TZ) bench-loop start: $LABEL ($TOTAL tasks)"
run_arm "$BASE" "--baseline" no || exit 1
run_arm "$ROUTED" "--selection-strategy lens" yes || exit 1
# Final energy audit is printed so 'how many scores were real' is a
# number in the log, not a question someone has to remember to ask.
energies_ok "$ROUTED"
echo "$(date -u +%FT%TZ) ALL DONE"
