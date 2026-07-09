#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"

RENDERED="$("$ROOT/scripts/openshift/render.sh" "$ENV_FILE")"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "Applying ATLAS OpenShift PVCs in namespace ${ATLAS_NAMESPACE}..."
oc apply -n "$ATLAS_NAMESPACE" -f "$RENDERED/10-storage.yaml"
oc get pvc -n "$ATLAS_NAMESPACE" -l app.kubernetes.io/part-of=atlas-openshift
