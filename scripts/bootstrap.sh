#!/bin/bash
#
# This script runs the Synadia Platform trial on your system by cloning the git
# repository, running Docker containers, and bootstrapping the system.

set -eu

git clone https://github.com/synadia-io/platform-trial.git
cd ./platform-trial || (echo './platform-trial does not exist' || exit 1)

declare -r SYNADIA_CR_SERVER=registry.synadia.io
declare SYNADIA_CR_USERNAME="${SYNADIA_CR_USERNAME-}"
declare SYNADIA_CR_PASSWORD="${SYNADIA_CR_PASSWORD-}"

if [ -z "$SYNADIA_CR_USERNAME" ]; then
  read -rp "$SYNADIA_CR_SERVER username: " SYNADIA_CR_USERNAME
fi

if [ -z "$SYNADIA_CR_PASSWORD" ]; then
  read -srp "$SYNADIA_CR_SERVER password: " SYNADIA_CR_PASSWORD
  echo # add newline
fi

echo "$SYNADIA_CR_PASSWORD" | docker login --username "${SYNADIA_CR_USERNAME}" --password-stdin "$SYNADIA_CR_SERVER"

source start.sh
