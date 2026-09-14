#!/usr/bin/env bash
#
# Stop the Synadia Platform trial started by start-k8s.sh by deleting the kind
# cluster. Deleting the cluster removes the PVCs with it.

set -euo pipefail

cd "$(dirname "$0")/.."

declare -r CLUSTER_NAME='platform-trial'

if ! command -v kind >/dev/null 2>&1; then
  echo 'missing kind' >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "kind cluster '$CLUSTER_NAME' is not running"
fi
