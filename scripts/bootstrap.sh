#!/usr/bin/env bash
#
# This script runs the Synadia Platform trial on your system by cloning the git
# repository, running Docker containers, and bootstrapping the system.

set -euo pipefail

# === Usage ===
declare debug=
declare interactive=
declare password_stdin=

usage(){
>&2 cat <<EOF
Usage: $0 [<flags>]

Bootstrap the Synadia Platform trial

  -h, --help
    Print this usage message

  -i, --interactive
    Prompt for Synadia container registry credentials interactively

  -p, --password-stdin
    Read the Synadia container registry password from stdin

  --debug
    Output all commands
EOF
exit 1
}

# Transform long flags to short flags without use of `eval`
args=( )
for arg; do
  case "$arg" in
    --help)            args+=( -h );;
    --debug)           args+=( -e );;
    --interactive)     args+=( -i );;
    --password-stdin)  args+=( -p );;
    *)                 args+=( "$arg" );;
  esac
done

# handle empty array
set -- "${args[@]+"${args[@]}"}"

# Handle args
while getopts 'heip' opt; do
  case $opt in
    h) usage ;;
    e) debug=1 ;;
    i) interactive=1 ;;
    p) password_stdin=1 ;;
    *)
      >&2 echo "Unsupported option: $1"
      usage ;;
  esac
done

if [ -n "$debug" ]; then
  set -x
  pwd
fi

git clone https://github.com/synadia-io/platform-trial.git
cd ./platform-trial || (echo './platform-trial does not exist' || exit 1)

# shellcheck source=./common.sh
. ./scripts/common.sh

declare -r SYNADIA_CR_SERVER=registry.synadia.io
declare SYNADIA_CR_USERNAME="${SYNADIA_CR_USERNAME-}"
declare SYNADIA_CR_PASSWORD="${SYNADIA_CR_PASSWORD-}"

if [ -n "$password_stdin" ]; then
  IFS= read -r SYNADIA_CR_PASSWORD </dev/stdin
fi

if [ -n "$interactive" ]; then
  read -rp "$SYNADIA_CR_SERVER username: " SYNADIA_CR_USERNAME < /dev/tty
fi

if [ -n "$interactive" ]; then
  read -srp "$SYNADIA_CR_SERVER password: " SYNADIA_CR_PASSWORD < /dev/tty
  echo # add newline after reading silent input
fi

if [ -z "$SYNADIA_CR_USERNAME" ] && [ -z "$SYNADIA_CR_PASSWORD" ]; then
  red "\nFailed to find Synadia container registry credentials\n\nSet $(bold SYNADIA_CR_USERNAME) and $(bold SYNADIA_CR_PASSWORD) environment variables or enable interactive mode with $(bold '--interactive')"
  exit 1
elif [ -z "$SYNADIA_CR_USERNAME" ]; then
  red "\nFailed to find Synadia container registry username\n\nSet $(bold SYNADIA_CR_USERNAME) environment variable or enable interactive mode with $(bold '--interactive')"
  exit 1
elif [ -z "$SYNADIA_CR_PASSWORD" ]; then
  red "\nFailed to find Synadia container registry password\n\nSet $(bold SYNADIA_CR_PASSWORD) environment variable, pipe from stdin with $(bold '--password-stdin'), or enable interactive mode with $(bold '--interactive')"
  exit 1
fi

echo "$SYNADIA_CR_PASSWORD" | docker login --username "${SYNADIA_CR_USERNAME}" --password-stdin "$SYNADIA_CR_SERVER"

cd ./scripts
chmod u+x ./start.sh
source ./start.sh
