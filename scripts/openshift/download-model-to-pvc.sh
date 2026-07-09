#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${ATLAS_NAMESPACE:?set ATLAS_NAMESPACE}"
: "${ATLAS_MODEL_PVC:?set ATLAS_MODEL_PVC}"
: "${ATLAS_MODEL_FILE:?set ATLAS_MODEL_FILE}"
: "${ATLAS_MODEL_URL:?set ATLAS_MODEL_URL}"
: "${ATLAS_KUEUE_QUEUE:=unreserved}"

POD="atlas-model-downloader"

oc delete pod -n "$ATLAS_NAMESPACE" "$POD" --ignore-not-found=true >/dev/null 2>&1 || true

cat <<YAML | oc apply -n "$ATLAS_NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels:
    app.kubernetes.io/name: ${POD}
    app.kubernetes.io/part-of: atlas-openshift
    kueue.x-k8s.io/queue-name: ${ATLAS_KUEUE_QUEUE}
spec:
  restartPolicy: Never
  containers:
  - name: downloader
    image: docker.io/library/alpine:3.20
    command:
    - /bin/sh
    - -lc
    - |
      set -eu
      cd /models
      echo "Target: ${ATLAS_MODEL_FILE}"
      if [ -s "${ATLAS_MODEL_FILE}" ]; then
        echo "Existing file found; verifying if hash is configured."
      else
        echo "Downloading ${ATLAS_MODEL_URL}"
        wget -c -O "${ATLAS_MODEL_FILE}.part" "${ATLAS_MODEL_URL}"
        mv "${ATLAS_MODEL_FILE}.part" "${ATLAS_MODEL_FILE}"
      fi
      if [ -n "${ATLAS_MODEL_SHA256:-}" ]; then
        echo "${ATLAS_MODEL_SHA256}  ${ATLAS_MODEL_FILE}" | sha256sum -c -
      else
        echo "No ATLAS_MODEL_SHA256 set; skipping hash verification."
      fi
      ls -lh "${ATLAS_MODEL_FILE}"
    volumeMounts:
    - name: models
      mountPath: /models
  volumes:
  - name: models
    persistentVolumeClaim:
      claimName: ${ATLAS_MODEL_PVC}
YAML

oc wait -n "$ATLAS_NAMESPACE" --for=condition=PodScheduled "pod/${POD}" --timeout=5m

for _ in $(seq 1 120); do
  if oc logs -n "$ATLAS_NAMESPACE" -f "pod/${POD}"; then
    break
  fi
  phase="$(oc get pod -n "$ATLAS_NAMESPACE" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
    oc logs -n "$ATLAS_NAMESPACE" "pod/${POD}" || true
    break
  fi
  sleep 5
done

oc wait -n "$ATLAS_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" --timeout=24h
oc delete pod -n "$ATLAS_NAMESPACE" "$POD" --ignore-not-found=true >/dev/null 2>&1 || true
