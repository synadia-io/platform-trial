#!/bin/bash
#
# Stop the Synadia Platform trial containers started by start.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

# Container engine; docker by default, podman with --podman/-p
engine='docker'
case "${1-}" in
  -p|--podman) engine='podman' ;;
esac

if "$engine" compose version >/dev/null 2>&1; then
  $engine compose down --volumes
else
  "${engine}-compose" down --volumes
fi
