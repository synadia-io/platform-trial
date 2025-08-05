#!/usr/bin/env bash
#
# This script runs the Synadia Platform trial on your system by running Docker
# containers and bootstrapping the system.

# shellcheck disable=SC2181

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=./common.sh
. ./scripts/common.sh

# === Usage ===
declare copy_password=
declare debug=
declare detach=
declare open=

usage(){
>&2 cat <<EOF
Usage: $0 [<flags>]

Start the Synadia Platform trial

  -h, --help
    Print this usage message

  -d, --detach
    Don't stop the Docker containers on SIGINT

  -o, --open
    Open the Control Plane UI in the default web browser automatically

  --debug
    Output all commands
EOF
exit 1
}

# Transform long flags to short flags without use of `eval`
args=( )
for arg; do
  case "$arg" in
    --help)          args+=( -h );;
    --copy-password) args+=( -c );;
    --detach)        args+=( -d );;
    --debug)         args+=( -e );;
    --open)          args+=( -o );;
    *)               args+=( "$arg" );;
  esac
done

# handle empty array
set -- "${args[@]+"${args[@]}"}"

# Handle args
while getopts 'hcdeo' opt; do
  case $opt in
    h) usage ;;
    c) copy_password=1 ;;
    d) detach=1 ;;
    e) debug=1 ;;
    o) open=1 ;;
    *)
      >&2 echo "Unsupported option: $1"
      usage ;;
  esac
done

if [ -n "$debug" ]; then
  set -x
  pwd
fi

# === Common functions ===
# check if the command exists
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# generate an alphanumeric password with openssl, falling back if openssl is not installed
generate_password() {
  if check_command openssl; then
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 16
  else
    printf 'admin'
  fi
}

# find control-plane container errors
find_errors() {
  $DOCKER_COMPOSE_CMD logs control-plane | grep -C1 '\[ERROR\]'
}

# Copy to the clipboard, depending on what CLI tools are available
copy_to_clipboard() {
  # macOS
  if check_command pbcopy; then
    printf "%s" "$1" | pbcopy
   # WSL
  elif check_command clip.exe; then
    printf "%s" "$1" | clip.exe
  # Linux
  elif check_command xsel; then
    printf "%s" "$1" | xsel --input --clipboard
  # Linux
  elif check_command xclip; then
    printf "%s" "$1" | xclip -selection clipboard
  fi
}

# Retry the command until it succeeds or the retry limit is reached
retry_with_backoff() {
  set +e
  CMD="$1"
  MAX_RETRY="${2-10}"
  RESULT="$($CMD)"
  rt="$?"
  local retries=1
  while [ "$rt" -ne 0 ]; do
    sleep 1
    echo "Retrying... ($retries/$MAX_RETRY)"
    RESULT="$($CMD)"
    rt="$?"
    (( retries+=1 ))
    if [ $retries -gt "$MAX_RETRY" ]; then
      red "Max retries reached ($MAX_RETRY)" >&2
      exit "$rt"
    fi
  done
  printf '%s' "$RESULT"
  set -e
}

# Use `docker compose`, falling back to `docker-compose` if not available
declare DOCKER_COMPOSE_CMD=
set_docker_compose() {
  set +e
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD='docker compose'
  elif docker-composer version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD='docker-compose'
  fi
  set -e
}

declare -r NATS_BIN="$(command -v nats)"

# === Common vars ===
export DOCKER_CLI_HINTS=false

declare -r BASE_URL='localhost:8080/api/core/beta'
declare -r ADMIN_USERNAME=admin
# shellcheck disable=SC2155
declare -r ADMIN_PASSWORD="$(generate_password)"
declare ADMIN_TOKEN=''

# Make an API request with the generated admin token
request() {
  METHOD="$1"
  URL="$BASE_URL$2"
  echo "$METHOD $URL" 1>&2

  OUTPUT_FILE=$(mktemp)
  HTTP_CODE=$(curl \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -X "$METHOD" \
    --silent \
    --output "$OUTPUT_FILE" \
    --connect-timeout 30 \
    --write-out "%{http_code}" \
    "${@:3}" \
    "$URL")

  if [ "${HTTP_CODE}" -gt 399 ]; then
    red "$1 $URL failed with response: [$HTTP_CODE] $(cat "$OUTPUT_FILE")" >&2
    exit "${HTTP_CODE}"
  fi
  cat "$OUTPUT_FILE"
  rm "$OUTPUT_FILE"
}

# === Verify required commands ===
docker_error_msg=$(cat <<EOF

If you do not have Docker installed, refer to the $(link 'https://docs.docker.com/get-docker/' 'Get Docker') documentation for instructions on how to install Docker Desktop or $(link 'https://docs.docker.com/engine/install/' 'Docker Engine') on your plaform.

An alternate option is $(link 'https://podman.io/' 'Podman'), which is a daemonless container engine that can be used as a drop-in replacement for Docker.
If this is preferred, and $(bold 'podman compose') is configured properly, any reference to $(bold 'docker') in the commands below can be replaced with $(bold 'podman').
EOF
)

if ! check_command docker; then
  echo -e "missing $(bold docker)$docker_error_msg"
  exit 1
fi

set_docker_compose
if [ -z "$DOCKER_COMPOSE_CMD" ]; then
  echo -e "missing $(bold 'docker compose') (or $(bold 'docker-compose'))$docker_error_msg 2>&1" >&2
  exit 1
fi

if ! check_command jq 2>&1; then
  echo -e "missing $(bold jq); install at $(link 'https://jqlang.github.io/jq/' 'https://jqlang.github.io/jq/')" >&2
  exit 1
fi

# === Prerequisites ===
# Make sure we have permission to pull from the container registry
docker pull registry.synadia.io/control-plane:latest \
  || (echo -e "\nMake sure to run $(bold 'docker login registry.synadia.io')\n\nIf you do not have credentials for the container registry, $(link 'https://synadia.com/platform/trial' 'sign up here')." && exit 1)

# === Start Control Plane ===
docker_cleanup() {
  $DOCKER_COMPOSE_CMD down --volumes
  exit 0
}

print_control_plane_errors() {
  rv=$?
  if [ "$rv" -ne 0 ]; then
    $DOCKER_COMPOSE_CMD logs control-plane | grep '\[ERROR\]'
  fi
  exit "$rv"
}

CONTAINER_RUNNING_COUNT=$($DOCKER_COMPOSE_CMD ps --status running --format json)
if [ -n "$CONTAINER_RUNNING_COUNT" ]; then
  red 'platform-trial is already running, exiting.' >&2
  exit 1
fi

# Stop docker compose on interrupt
if [ -z "$detach" ]; then
  trap docker_cleanup SIGINT
fi

# Print errors from control-plane container if non-zero exit
trap print_control_plane_errors EXIT

$DOCKER_COMPOSE_CMD up --detach control-plane
echo 'Waiting for control-plane to be ready...'
grep --quiet 'control plane started' <($DOCKER_COMPOSE_CMD logs --follow control-plane)
echo 'control-plane is ready.'

# Wait until control-plane succesfully starts before (over)writing .env file
printf '' > .env
echo "ADMIN_USERNAME=$ADMIN_USERNAME" >> .env
echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" >> .env
bold '\nSaved ADMIN_USERNAME and ADMIN_PASSWORD to .env\n'

# === Login to Control Plane ===
ADMIN_TOKEN=$(request POST /admin/app-user/ \
  --data "$(cat <<EOF | jq --compact-output
{
  "username": "$ADMIN_USERNAME",
  "password": "$ADMIN_PASSWORD",
  "generate_token": true
}
EOF
)" | jq --raw-output .token)

echo "ADMIN_TOKEN=\"${ADMIN_TOKEN}\"" >> .env
bold '\nSaved ADMIN_TOKEN to .env\n'

TEAM_ID=$(request GET /teams/ | jq --raw-output '.items[0].id')

SYSTEM_RESPONSE=$(request POST "/teams/${TEAM_ID}/systems" \
  --data "$(cat <<EOF | jq --compact-output
{
  "name": "trial",
  "url": "nats://nats1:4222,nats://nats2:4222,nats://nats3:4222",
  "jetstream_enabled": true
}
EOF
)")

# === Configure NATS Settings ===
SYSTEM_ID=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .id)
OPERATOR_JWT=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .operator_jwt)
SYSTEM_ACCOUNT=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .operator_claims.nats.system_account)
SYSTEM_ACCOUNT_JWT=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .system_account_jwt)
JETSTREAM_DOMAIN=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .jetstream_domain)

JS_CONF=$(cat <<EOF
jetstream {
  store_dir: "./data/js"
  max_mem: 0
  max_file: 10GB
  domain: $JETSTREAM_DOMAIN
}

EOF
)

NATS_CONF=$(cat <<EOF
$JS_CONF

operator: $OPERATOR_JWT
system_account: $SYSTEM_ACCOUNT

resolver {
  dir: "./data/jwt"
  type: full
  allow_delete: true
  interval: "2m"
  timeout: "1.9s"
}

resolver_preload: {
  ${SYSTEM_ACCOUNT}: ${SYSTEM_ACCOUNT_JWT}
}
EOF
)

echo "$NATS_CONF" > shared.conf

request PATCH "/systems/$SYSTEM_ID/?test_connection=false" --data '{"connection_type":"Direct"}' >/dev/null

# === Start the NATS cluster ===
$DOCKER_COMPOSE_CMD up --detach --wait nats1 nats2 nats3

# === Test the NATS connection ===
request PATCH "/systems/$SYSTEM_ID/?test_connection=true" \
  --data "$(cat <<EOF | jq --compact-output
{
  "direct_connection_opts": {
    "override_urls": "",
    "tls_insecure_skip_verify": false,
    "tls_mode": "Auto"
  }
}
EOF
)" >/dev/null

# Wait until NATS system is connected to control plane
checkSystemState() {
  SYSTEM_STATE=$(request GET "/systems/$SYSTEM_ID" | jq --raw-output .state)
  if [ "$SYSTEM_STATE" != 'Connected' ]; then
    exit 1
  fi
}
retry_with_backoff checkSystemState || (rt=$?; red 'System failed to connect to NATS server' >&2; exit $rt)

# === Create a user and account ===
ACCOUNT_ID=$(request POST "/systems/$SYSTEM_ID/accounts" --data '{"name":"trial"}' | jq --raw-output .id)

SK_GROUP_ID=$(request GET "/accounts/${ACCOUNT_ID}/account-sk-groups/" | jq --raw-output '.items[0].id')

NATS_USER_ID=$(request POST "/accounts/${ACCOUNT_ID}/nats-users/" \
  --data "$(cat <<EOF | jq --compact-output
{
  "name": "trial",
  "sk_group_id": "${SK_GROUP_ID}",
  "jwt_expires_in_secs": 0
}
EOF
  )" | jq --raw-output .id)

request POST "/nats-users/${NATS_USER_ID}/creds" >trial.creds

# === Setup Nexus ===

# === Create an account and users ===
NEXUS_ACCOUNT_ID=$(request POST "/systems/$SYSTEM_ID/accounts" --data '{"name":"nexus"}' | jq --raw-output .id)

NEXUS_SK_GROUP_ID=$(request GET "/accounts/${NEXUS_ACCOUNT_ID}/account-sk-groups/" | jq --raw-output '.items[0].id')

NEXUS_NODE_NATS_USER_ID=$(request POST "/accounts/${NEXUS_ACCOUNT_ID}/nats-users/" \
  --data "$(
    cat <<EOF | jq --compact-output
{
  "name": "nexus_node",
  "sk_group_id": "${NEXUS_SK_GROUP_ID}",
  "jwt_expires_in_secs": 0
}
EOF
  )" | jq --raw-output .id)

request POST "/nats-users/${NEXUS_NODE_NATS_USER_ID}/creds" >nexus-node.creds

# NEED PROGRAMATIC KEY
NEXUS_NEXLET_SK_SEED=$(request POST "/accounts/${NEXUS_ACCOUNT_ID}/account-sk-groups/" \
  --data "$(
    cat <<EOF | jq --compact-output
{
  "name": "nexus-nexlets",
  "programmatic": true
}
EOF
  )" | jq --raw-output .seed)

NEXUS_ACCT_PUBKEY=$(request GET "/accounts/${NEXUS_ACCOUNT_ID}" | jq --raw-output '.account_public_key')

generate_nex_node_config() {
  local node_num="$1"

  cat <<EOF >./configs/nex${node_num}.conf
{
  "name": "nex${node_num}",
  "nexus": "nexus",
  "tags": {
    "synadia-platform": "trial"
  },
  "node_seed": "$($NATS_BIN auth nkey gen server)",
  "nats": {
    "creds_file": "./nexus-node.creds",
    "servers": [
      "nats://nats1",
      "nats://nats2",
      "nats://nats3"
    ]
  },
  "creds_signing_key": "$NEXUS_NEXLET_SK_SEED",
  "creds_signing_key_account": "$NEXUS_ACCT_PUBKEY",
  "allow_remote_register": false,
  "logger": {
    "level": "info"
  },
  "nexlets": {
    "native": {
      "enabled": true,
      "registerType": "native"
    },
    "javascript-deno": {
      "enabled": true,
      "registerType": "javascript"
    }
  }
}
EOF
}

generate_nex_node_config 1
generate_nex_node_config 2
generate_nex_node_config 3

request PATCH "/systems/$SYSTEM_ID/platform-components/" \
  --data "$(
    cat <<EOF | jq --compact-output
{
  "type": "workloads",
  "enabled": true,
  "config": {
    "account": "$NEXUS_ACCOUNT_ID"
  }
}
EOF
  )"

# === Setup HTTP Gateway ===

# === Create an account, user, and KV bucket ===
HTTP_GATEWAY_ACCOUNT_ID=$(request POST "/systems/$SYSTEM_ID/accounts" --data '{"name":"http-gateway"}' | jq --raw-output .id)

HTTP_GATEWAY_SK_GROUP_ID=$(request GET "/accounts/${HTTP_GATEWAY_ACCOUNT_ID}/account-sk-groups/" | jq --raw-output '.items[0].id')

HTTP_GATEWAY_NATS_USER_ID=$(request POST "/accounts/${HTTP_GATEWAY_ACCOUNT_ID}/nats-users/" \
  --data "$(cat <<EOF | jq --compact-output
{
  "name": "http-gateway",
  "sk_group_id": "${HTTP_GATEWAY_SK_GROUP_ID}",
  "jwt_expires_in_secs": 0
}
EOF
)" | jq --raw-output .id)

request POST "/nats-users/${HTTP_GATEWAY_NATS_USER_ID}/creds" > http-gateway.creds

createKVBucket() {
  request POST "/accounts/${HTTP_GATEWAY_ACCOUNT_ID}/jetstream/kv-buckets/" --data '{"bucket":"tokens"}' >/dev/null
}
retry_with_backoff "createKVBucket" || (rt=$?; red 'Failed to create KV bucket for HTTP Gateway account' >&2; exit $rt)

request PATCH "/systems/$SYSTEM_ID/platform-components/" \
  --data "$(
    cat <<EOF | jq --compact-output
{
  "type": "http_gateway",
  "enabled": true,
  "config": {
    "account": "${HTTP_GATEWAY_ACCOUNT_ID}",
    "token_bucket": "tokens",
    "url": "http://localhost:8081"
  }
}
EOF
)" >/dev/null

$DOCKER_COMPOSE_CMD up --detach --wait nex1
$DOCKER_COMPOSE_CMD up --detach --wait nex2
$DOCKER_COMPOSE_CMD up --detach --wait nex3
$DOCKER_COMPOSE_CMD up --detach --wait http-gateway

HTTP_GATEWAY_TOKEN=$(request POST "/nats-users/${HTTP_GATEWAY_NATS_USER_ID}/http-gw-token" | jq --raw-output .token)
echo "HTTP_GATEWAY_TOKEN=\"${HTTP_GATEWAY_TOKEN}\"" >> .env
bold '\nSaved HTTP_GATEWAY_TOKEN to .env\n'

cat <<EOF
Done bootstrapping Synadia Platform, open the UI at $(link 'http://localhost:8080') and login with:

    username: $(bold 'admin')
    password: $(bold "$ADMIN_PASSWORD")

Check out the HTTP Gateway API documentation at $(link 'http://localhost:8081/api/')
EOF

# if --open, open the browser to control plane
if [ -n "$open" ]; then
  case "$(uname -s)" in
    Linux)
      if check_command xdg-open; then
        xdg-open "http://localhost:8080"
      fi
      ;;
    Darwin)
      open "http://localhost:8080"
      ;;
  esac
fi

if [ -n "$copy_password" ]; then
  copy_to_clipboard "$ADMIN_PASSWORD"
  echo -e 'Copied admin password to the clipboard'
fi
