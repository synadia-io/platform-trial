#!/usr/bin/env bash
#
# Shared Control Plane bootstrap logic for the Synadia Platform trial.
#
# Both scripts/start.sh (Docker Compose) and scripts/start-k8s.sh (Kubernetes)
# source this file. It holds the Control Plane API calls that are identical on
# both runtimes, so the sequence lives in one place.
#
# The caller must set these before it calls any function here:
#   BASE_URL     Control Plane API base, e.g. localhost:8080/api/core/beta
#   ADMIN_TOKEN  Admin token; cp_create_admin sets it
#
# shellcheck shell=bash

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

# generate an alphanumeric password with openssl, falling back if openssl is not installed
generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 16
  else
    printf 'admin'
  fi
}

# generate a NUID (https://github.com/nats-io/nuid): 22 base62 characters
generate_nuid() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 22 || true
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

# Create the admin app user and export ADMIN_TOKEN.
#   $1 = username, $2 = password
cp_create_admin() {
  local username="$1" password="$2"
  ADMIN_TOKEN=$(request POST /admin/app-user/ \
    --data "$(jq --compact-output --null-input \
      --arg u "$username" --arg p "$password" \
      '{username: $u, password: $p, generate_token: true}')" \
    | jq --raw-output .token)
  export ADMIN_TOKEN
}

# Print the first team ID
cp_first_team_id() {
  request GET /teams/ | jq --raw-output '.items[0].id'
}

# Create a NATS system and print the raw response JSON.
#   $1 = team ID, $2 = system name, $3 = comma-separated NATS URLs
cp_create_system() {
  local team_id="$1" name="$2" urls="$3"
  request POST "/teams/${team_id}/systems" \
    --data "$(jq --compact-output --null-input \
      --arg n "$name" --arg u "$urls" \
      '{name: $n, url: $u, jetstream_enabled: true}')"
}

# Render a nats-server config from a system-create response.
#   $1 = system response JSON
cp_render_nats_conf() {
  local response="$1"
  local operator_jwt system_account system_account_jwt jetstream_domain
  operator_jwt=$(echo "$response" | jq --raw-output .operator_jwt)
  system_account=$(echo "$response" | jq --raw-output .operator_claims.nats.system_account)
  system_account_jwt=$(echo "$response" | jq --raw-output .system_account_jwt)
  jetstream_domain=$(echo "$response" | jq --raw-output .jetstream_domain)

  cat <<EOF
jetstream {
  store_dir: "./data/js"
  max_mem: 0
  max_file: 10GB
  domain: $jetstream_domain
}

operator: $operator_jwt
system_account: $system_account

resolver {
  dir: "./data/jwt"
  type: full
  allow_delete: true
  interval: "2m"
  timeout: "1.9s"
}

resolver_preload: {
  ${system_account}: ${system_account_jwt}
}
EOF
}

# Render only the operator/system-account block from a system-create response.
#
# The Kubernetes path uses this instead of cp_render_nats_conf: the nats chart
# already writes `jetstream` and `resolver` into its own nats.conf. Emitting
# them again here would silently override the chart's values, because a later
# block wins in nats-server config. Only the operator identity is needed.
#   $1 = system response JSON
cp_render_operator_conf() {
  local response="$1"
  local operator_jwt system_account system_account_jwt
  operator_jwt=$(echo "$response" | jq --raw-output .operator_jwt)
  system_account=$(echo "$response" | jq --raw-output .operator_claims.nats.system_account)
  system_account_jwt=$(echo "$response" | jq --raw-output .system_account_jwt)

  cat <<EOF
operator: $operator_jwt
system_account: $system_account

resolver_preload: {
  ${system_account}: ${system_account_jwt}
}
EOF
}

# Print the JetStream domain from a system-create response
cp_jetstream_domain() {
  echo "$1" | jq --raw-output .jetstream_domain
}

# Wait until the system reports Connected
cp_wait_system_connected() {
  local system_id="$1"
  checkSystemState() {
    SYSTEM_STATE=$(request GET "/systems/$system_id" | jq --raw-output .state)
    if [ "$SYSTEM_STATE" != 'Connected' ]; then
      exit 1
    fi
  }
  retry_with_backoff checkSystemState \
    || (rt=$?; red 'System failed to connect to NATS server' >&2; exit $rt)
}

# Create an account and print its ID.
#   $1 = system ID, $2 = account name
cp_create_account() {
  request POST "/systems/$1/accounts" \
    --data "$(jq --compact-output --null-input --arg n "$2" '{name: $n}')" \
    | jq --raw-output .id
}

# Create a NATS user in an account and print its ID.
#   $1 = account ID, $2 = user name
cp_create_nats_user() {
  local account_id="$1" name="$2" sk_group_id
  sk_group_id=$(request GET "/accounts/${account_id}/account-sk-groups/" \
    | jq --raw-output '.items[0].id')
  request POST "/accounts/${account_id}/nats-users/" \
    --data "$(jq --compact-output --null-input \
      --arg n "$name" --arg g "$sk_group_id" \
      '{name: $n, sk_group_id: $g, jwt_expires_in_secs: 0}')" \
    | jq --raw-output .id
}

# Enable a platform component on the system and print its `pcm_` token. The flow
# is: enable the component, re-read the system to find the component ID, then
# fetch the component token.
#   $1 = system ID, $2 = component type (e.g. "workloads", "catalog")
#   $3 = optional component config as a JSON object (e.g. {"catalog_id":"..."})
get_platform_component_token() {
  local system_id="$1"
  local component_type="$2"
  local config="${3-}"

  local body
  if [ -n "$config" ]; then
    body=$(jq --compact-output --null-input --arg type "$component_type" --argjson config "$config" \
      '{type: $type, enabled: true, config: $config}')
  else
    body=$(jq --compact-output --null-input --arg type "$component_type" '{type: $type, enabled: true}')
  fi

  request PATCH "/systems/${system_id}/platform-components/" --data "$body" >/dev/null

  local component_id
  component_id=$(request GET "/systems/${system_id}" \
    | jq --raw-output --arg type "$component_type" '.platform_components.components[] | select(.type == $type) | .id')

  if [ -z "$component_id" ] || [ "$component_id" = 'null' ]; then
    red "Failed to find ${component_type} platform component ID for system ${system_id}" >&2
    exit 1
  fi

  request GET "/systems/${system_id}/platform-components/${component_id}/tokens" | jq --raw-output .token
}
