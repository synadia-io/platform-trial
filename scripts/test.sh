#!/usr/bin/env bash
#
# This script checks that the Synadia Platform trial is running correctly.

set -euo pipefail

# shellcheck source=./common.sh
. ./scripts/common.sh

# Check can connect to HTTP Gateway
HTTP_GATEWAY_TOKEN=$(grep HTTP_GATEWAY_TOKEN .env | cut -d= -f2 | tr -d '"')
curl -fsSL -X GET "http://127.0.0.1:8081/v1/kvm/buckets" \
  -H 'accept: application/json' \
  -H "authorization: $HTTP_GATEWAY_TOKEN"
