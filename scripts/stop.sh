#!/bin/bash
# 
# Stop the Synadia Platform trial Docker containers started by start.sh.

set -euo pipefail

docker compose down --volumes
