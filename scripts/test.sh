#!/usr/bin/env bash
#
# This script checks that the Synadia Platform trial is running correctly.
#
# Usage: ./scripts/test.sh [-p|--podman]

set -euo pipefail

# shellcheck source=./common.sh
. ./scripts/common.sh

# Container engine; docker by default, podman with --podman/-p
engine='docker'
case "${1-}" in
  -p|--podman) engine='podman' ;;
esac

compose() {
  if "$engine" compose version >/dev/null 2>&1; then
    "$engine" compose "$@"
  else
    "${engine}-compose" "$@"
  fi
}

# Check can connect to HTTP Gateway
HTTP_GATEWAY_TOKEN=$(grep HTTP_GATEWAY_TOKEN .env | cut -d= -f2 | tr -d '"')
curl -fsSL -X GET "http://127.0.0.1:8081/v1/kvm/buckets" \
  -H 'accept: application/json' \
  -H "authorization: $HTTP_GATEWAY_TOKEN"

# Check the Nex node started successfully.
# start.sh renders nex-ce.config.json only when it starts Nex, so skip otherwise.
if [ -f nex-ce.config.json ]; then
  if [ -z "$(compose ps --quiet nex)" ]; then
    red 'Nex container is not running' >&2
    exit 1
  fi

  # The node logs "nex node ready" shortly after the container starts
  ready=
  for _ in $(seq 1 30); do
    if compose logs nex 2>&1 | grep -q 'nex node ready'; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ -z "$ready" ]; then
    red 'Nex node did not become ready' >&2
    compose logs nex >&2
    exit 1
  fi

  # The node can log "ready" even when a nexlet fails, so errors and a node
  # without agents also count as failures
  if compose logs nex 2>&1 | grep -E '\[ERROR\]|nex node started without any agents' >&2; then
    red 'Nex node logged errors or started without any agents' >&2
    exit 1
  fi

  bold '\nNex node started successfully.'
fi
