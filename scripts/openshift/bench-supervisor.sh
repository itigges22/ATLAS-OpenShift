#!/bin/sh
# Pod-level supervisor for the bench loop. Runs as the atlas-bench pod's
# command so the benchmark survives container restarts (a 2026-07-12 OOM
# kill silently took the nohup'd loop with it and the pod came back idle;
# checkpoints and logs live on the PVC, so resuming is always safe).
#
# Arm/disarm by file, not by process: `touch /bench/RUN_ENABLED` (the
# launcher writes the loop args into it); `rm /bench/RUN_ENABLED` stops
# relaunching (running loop is left alone — kill it separately).
while true; do
  if [ -f /bench/RUN_ENABLED ]; then
    alive=0
    for d in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
      case "$cmd" in *bench-loop.sh*) alive=1;; esac
    done
    if [ "$alive" = "0" ]; then
      ARGS=$(cat /bench/RUN_ENABLED)
      echo "=== SUPERVISOR relaunch $(date -u +%FT%TZ): bench-loop $ARGS ===" >> /bench/bench_loop_fixed.log
      # shellcheck disable=SC2086
      ATLAS_LCB_RELEASE="${ATLAS_LCB_RELEASE:-release_v6only}" \
        ATLAS_PARALLEL_TASKS="${ATLAS_PARALLEL_TASKS:-4}" \
        nohup sh /bench/bench-loop.sh $ARGS >> /bench/bench_loop_fixed.log 2>&1 &
    fi
  fi
  sleep 60
done
