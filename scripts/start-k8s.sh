#!/usr/bin/env bash
#
# This script runs the Synadia Platform trial on a local Kubernetes cluster by
# creating a kind cluster, installing the platform Helm charts, and
# bootstrapping the system through the Control Plane API.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=./common.sh
. ./scripts/common.sh
# shellcheck source=./bootstrap-lib.sh
. ./scripts/bootstrap-lib.sh

# === Usage ===
declare debug=
declare keep_cluster=
declare nex=
declare open=
declare -r CLUSTER_NAME='platform-trial'
declare -r NAMESPACE='platform-trial'
declare -r WORKLOADS_NAMESPACE='nex-workloads'

# Chart versions are pinned so the trial is reproducible
declare -r CONTROL_PLANE_CHART_VERSION='1.14.0'
declare -r HTTP_GATEWAY_CHART_VERSION='0.1.3'
declare -r NATS_CHART_VERSION='2.14.6'

usage(){
>&2 cat <<EOF
Usage: $0 [<flags>]

Start the Synadia Platform trial on a local Kubernetes cluster (kind)

  -h, --help
    Print this usage message

  -k, --keep-cluster
    Reuse an existing kind cluster instead of failing

  -n, --nex
    Start the Nex node with the Kubernetes nexlets

  -o, --open
    Open the Control Plane UI in the default web browser automatically

  --debug
    Output all commands
EOF
exit 1
}

# Transform long flags to short flags without use of \`eval\`
args=( )
for arg; do
  case "$arg" in
    --help)          args+=( -h );;
    --debug)         args+=( -e );;
    --keep-cluster)  args+=( -k );;
    --nex)           args+=( -n );;
    --open)          args+=( -o );;
    *)               args+=( "$arg" );;
  esac
done

# handle empty array
set -- "${args[@]+"${args[@]}"}"

while getopts 'hekno' opt; do
  case $opt in
    h) usage ;;
    e) debug=1 ;;
    k) keep_cluster=1 ;;
    n) nex=1 ;;
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

check_command() {
  command -v "$1" >/dev/null 2>&1
}

# === Verify required commands ===
for cmd in kind kubectl helm jq; do
  if ! check_command "$cmd"; then
    red "missing $(bold "$cmd")" >&2
    case "$cmd" in
      kind)    echo -e "install at $(link 'https://kind.sigs.k8s.io/docs/user/quick-start/#installation')" >&2 ;;
      kubectl) echo -e "install at $(link 'https://kubernetes.io/docs/tasks/tools/')" >&2 ;;
      helm)    echo -e "install at $(link 'https://helm.sh/docs/intro/install/')" >&2 ;;
      jq)      echo -e "install at $(link 'https://jqlang.github.io/jq/')" >&2 ;;
    esac
    exit 1
  fi
done

# Nex needs `nk` to generate its node seed
if [ -n "$nex" ] && ! check_command nk; then
  red 'missing nk (Nex needs it to generate a node seed)' >&2
  echo -e "install with $(bold 'go install github.com/nats-io/nkeys/nk@latest')" >&2
  exit 1
fi

# === Registry credentials ===
declare -r SYNADIA_CR_SERVER=registry.synadia.io
declare SYNADIA_CR_USERNAME="${SYNADIA_CR_USERNAME-}"
declare SYNADIA_CR_PASSWORD="${SYNADIA_CR_PASSWORD-}"

if [ -z "$SYNADIA_CR_USERNAME" ] || [ -z "$SYNADIA_CR_PASSWORD" ]; then
  red "\nFailed to find Synadia container registry credentials\n\nSet $(bold SYNADIA_CR_USERNAME) and $(bold SYNADIA_CR_PASSWORD) environment variables.\n\nIf you do not have credentials, $(link 'https://synadia.com/platform/trial' 'sign up here')."
  exit 1
fi

# === Create the kind cluster ===
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if [ -z "$keep_cluster" ]; then
    red "kind cluster '$CLUSTER_NAME' already exists, exiting.\n\nDelete it with $(bold "./scripts/stop-k8s.sh"), or reuse it with $(bold '--keep-cluster')." >&2
    exit 1
  fi
  bold "\nReusing existing kind cluster '$CLUSTER_NAME'\n"
else
  bold "\nCreating kind cluster '$CLUSTER_NAME'...\n"
  kind create cluster --config k8s/kind-cluster.yaml
fi

declare -r KCTX="kind-${CLUSTER_NAME}"
kubectl --context "$KCTX" create namespace "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl --context "$KCTX" apply -f -
kubectl config set-context "$KCTX" --namespace "$NAMESPACE" >/dev/null

kc() { kubectl --context "$KCTX" --namespace "$NAMESPACE" "$@"; }

# === Image pull secret ===
create_pull_secret() {
  kubectl --context "$KCTX" --namespace "$1" \
    create secret docker-registry synadia-registry \
    --docker-server="$SYNADIA_CR_SERVER" \
    --docker-username="$SYNADIA_CR_USERNAME" \
    --docker-password="$SYNADIA_CR_PASSWORD" \
    --dry-run=client -o yaml \
  | kubectl --context "$KCTX" --namespace "$1" apply -f -
}
create_pull_secret "$NAMESPACE"

# === Helm repos ===
helm repo add synadia https://synadia-io.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null

# === Start Control Plane ===
bold '\nInstalling Control Plane...\n'
helm --kube-context "$KCTX" upgrade --install control-plane synadia/control-plane \
  --namespace "$NAMESPACE" \
  --version "$CONTROL_PLANE_CHART_VERSION" \
  --values k8s/control-plane.values.yaml \
  --set "imagePullSecret.username=${SYNADIA_CR_USERNAME}" \
  --set "imagePullSecret.password=${SYNADIA_CR_PASSWORD}" \
  --wait --timeout 5m

echo 'Waiting for control-plane to be ready...'
kc rollout status deployment/control-plane --timeout=5m

# === Common vars ===
declare -r BASE_URL='localhost:8080/api/core/beta'
declare -r ADMIN_USERNAME=admin
# shellcheck disable=SC2155
declare -r ADMIN_PASSWORD="$(generate_password)"
declare ADMIN_TOKEN=''

# Wait for the Control Plane API to answer through the kind port mapping
waitForAPI() {
  curl --silent --fail --output /dev/null "http://${BASE_URL%/api/core/beta}/" || exit 1
}
retry_with_backoff waitForAPI 30 >/dev/null \
  || (red 'Control Plane API did not become reachable on localhost:8080' >&2; exit 1)

printf '' > .env
echo "ADMIN_USERNAME=$ADMIN_USERNAME" >> .env
echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" >> .env
bold '\nSaved ADMIN_USERNAME and ADMIN_PASSWORD to .env\n'

# === Login to Control Plane ===
cp_create_admin "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
echo "ADMIN_TOKEN=\"${ADMIN_TOKEN}\"" >> .env
bold '\nSaved ADMIN_TOKEN to .env\n'

TEAM_ID=$(cp_first_team_id)

# In-cluster DNS: the Compose trial needs host.docker.internal to hairpin out to
# the host and back, Kubernetes resolves the NATS service directly.
#
# The name must be fully qualified. A bare "nats" only resolves inside
# $NAMESPACE, but connector workloads run in $WORKLOADS_NAMESPACE and would fail
# with "lookup nats ... no such host". This URL is signed into the operator JWT's
# operator_service_urls at creation, so it cannot be corrected later without
# re-bootstrapping the system.
SYSTEM_RESPONSE=$(cp_create_system "$TEAM_ID" trial \
  "nats://nats.${NAMESPACE}.svc.cluster.local:4222")

SYSTEM_ID=$(echo "$SYSTEM_RESPONSE" | jq --raw-output .id)

# === Configure NATS ===
# Render only the operator identity and hand it to the NATS pods as a Secret.
# nats.values.yaml pulls it in with an $include. The chart owns `jetstream` and
# `resolver`, so this file must not repeat them: in nats-server config a later
# block silently overrides an earlier one.
cp_render_operator_conf "$SYSTEM_RESPONSE" > shared.conf
JETSTREAM_DOMAIN=$(cp_jetstream_domain "$SYSTEM_RESPONSE")
kc create secret generic nats-resolver \
  --from-file=operator.conf=shared.conf \
  --dry-run=client -o yaml | kc apply -f -
bold '\nCreated nats-resolver secret from the generated operator config\n'

request PATCH "/systems/$SYSTEM_ID/?test_connection=false" --data '{"connection_type":"Direct"}' >/dev/null

# === Start the NATS cluster ===
bold '\nInstalling NATS...\n'
helm --kube-context "$KCTX" upgrade --install nats nats/nats \
  --namespace "$NAMESPACE" \
  --version "$NATS_CHART_VERSION" \
  --values k8s/nats.values.yaml \
  --set "config.jetstream.merge.domain=${JETSTREAM_DOMAIN}" \
  --wait --timeout 5m

kc rollout status statefulset/nats --timeout=5m

# === Test the NATS connection ===
request PATCH "/systems/$SYSTEM_ID/?test_connection=true" \
  --data "$(jq --compact-output --null-input \
    '{direct_connection_opts: {override_urls: "", tls_insecure_skip_verify: false, tls_mode: "Auto"}}')" >/dev/null

cp_wait_system_connected "$SYSTEM_ID"

# === Create a user and account ===
ACCOUNT_ID=$(cp_create_account "$SYSTEM_ID" trial)
NATS_USER_ID=$(cp_create_nats_user "$ACCOUNT_ID" trial)
request POST "/nats-users/${NATS_USER_ID}/creds" > trial.creds

# === Setup HTTP Gateway ===
HTTP_GATEWAY_ACCOUNT_ID=$(cp_create_account "$SYSTEM_ID" http-gateway)
HTTP_GATEWAY_NATS_USER_ID=$(cp_create_nats_user "$HTTP_GATEWAY_ACCOUNT_ID" http-gateway)
request POST "/nats-users/${HTTP_GATEWAY_NATS_USER_ID}/creds" > http-gateway.creds

createKVBucket() {
  request POST "/accounts/${HTTP_GATEWAY_ACCOUNT_ID}/jetstream/kv-buckets/" --data '{"bucket":"tokens"}' >/dev/null
}
retry_with_backoff "createKVBucket" \
  || (rt=$?; red 'Failed to create KV bucket for HTTP Gateway account' >&2; exit $rt)

request PATCH "/systems/$SYSTEM_ID/platform-components/" \
  --data "$(jq --compact-output --null-input --arg acct "$HTTP_GATEWAY_ACCOUNT_ID" \
    '{type: "http_gateway", enabled: true, config: {account: $acct, token_bucket: "tokens", url: "http://localhost:8081"}}')" >/dev/null

kc create secret generic http-gateway-creds \
  --from-file=nats.creds=http-gateway.creds \
  --dry-run=client -o yaml | kc apply -f -

bold '\nInstalling HTTP Gateway...\n'
helm --kube-context "$KCTX" upgrade --install http-gateway synadia/http-gateway \
  --namespace "$NAMESPACE" \
  --version "$HTTP_GATEWAY_CHART_VERSION" \
  --values k8s/http-gateway.values.yaml \
  --wait --timeout 5m

HTTP_GATEWAY_TOKEN=$(request POST "/nats-users/${HTTP_GATEWAY_NATS_USER_ID}/http-gw-token" | jq --raw-output .token)
echo "HTTP_GATEWAY_TOKEN=\"${HTTP_GATEWAY_TOKEN}\"" >> .env
bold '\nSaved HTTP_GATEWAY_TOKEN to .env\n'

# === Setup Nex (optional) ===
# The Kubernetes nexlets need no Podman socket: Nex creates workloads through
# the API server with its ServiceAccount.
# Wait until Control Plane's credential provider is serving on NATS.
#
# A system reports Connected as soon as Control Plane can reach NATS, but the
# credential-minting service comes up separately and retries on a ~20s loop: its
# first attempt fails when NATS is not listening yet. Nex asks that service for
# workload credentials on startup, gives up after 5 tries in ~5 seconds, and
# then logs "nex node ready" while running no agents at all. The pod stays
# Running, so nothing restarts it and the failure is silent.
#
# Control Plane logs "credential provider started" once the service is up, so
# wait for that line before starting Nex.
wait_for_credential_provider() {
  local attempts=30
  for _ in $(seq 1 "$attempts"); do
    if kc logs deployment/control-plane --tail=-1 2>/dev/null \
      | grep -q 'credential provider started'; then
      bold '\nControl Plane credential provider is serving\n'
      # The log line is written when the provider starts, not when its NATS
      # subscription is answering across the cluster. Nex has been seen to get
      # "no responders" 17s after this line appears, so give the subscription
      # time to propagate before starting the node.
      sleep 15
      return 0
    fi
    sleep 2
  done
  red "Credential provider did not start after $(( attempts * 2 ))s" >&2
  red 'Nex would start without agents, so stopping here.' >&2
  exit 1
}

start_nex() {
  if [ -z "$nex" ]; then
    bold "\nSkipping Nex (pass $(bold '--nex') to enable).\n"
    return 0
  fi

  wait_for_credential_provider

  NEX_NODE_SEED=$(nk -gen server)

  NEX_PLATFORM_TOKEN=$(get_platform_component_token "$SYSTEM_ID" workloads)
  NEX_CATALOG_ID=$(generate_nuid)
  NEX_CATALOG_TOKEN=$(get_platform_component_token "$SYSTEM_ID" catalog \
    "$(jq --compact-output --null-input --arg id "$NEX_CATALOG_ID" '{catalog_id: $id}')")

  request PATCH "/accounts/${ACCOUNT_ID}/" \
    --data '{"connectors": true, "workloads": true}' >/dev/null
  bold '\nEnabled workloads and connectors on the trial account\n'

  jq \
    --arg node_seed "$NEX_NODE_SEED" \
    --arg platform_token "$NEX_PLATFORM_TOKEN" \
    --arg catalog_id "$NEX_CATALOG_ID" \
    --arg catalog_token "$NEX_CATALOG_TOKEN" \
    --arg ns "$WORKLOADS_NAMESPACE" \
    '.node_seed = $node_seed
     | .platform.token = $platform_token
     | .catalog.id = $catalog_id
     | .catalog.token = $catalog_token
     | .nexlets["containers-kubernetes"].k8sNamespace = $ns
     | .nexlets["connectors-kubernetes"].k8sNamespace = $ns' \
    k8s/nex-ce.config.json.template > nex-ce.config.json
  bold '\nRendered nex-ce.config.json from k8s/nex-ce.config.json.template\n'

  kc create secret generic nex-config \
    --from-file=config.json=nex-ce.config.json \
    --dry-run=client -o yaml | kc apply -f -

  # Substitute the namespace and a config checksum, so a changed config restarts
  # the node rather than leaving a stale one running.
  CONFIG_CHECKSUM=$(shasum -a 256 nex-ce.config.json 2>/dev/null | cut -d' ' -f1 \
    || sha256sum nex-ce.config.json | cut -d' ' -f1)
  # Apply without a forced namespace. The manifest spans two namespaces: the
  # Deployment and ServiceAccount live in $NAMESPACE, while the Role and
  # RoleBinding live in $WORKLOADS_NAMESPACE. Passing --namespace makes kubectl
  # reject the objects that name a different one, and it still exits 0, so the
  # RBAC would go missing without any error.
  sed -e "s|NEX_NAMESPACE|${NAMESPACE}|g" \
      -e "s|CONFIG_CHECKSUM|${CONFIG_CHECKSUM}|g" \
      k8s/nex-ce.yaml \
    | kubectl --context "$KCTX" apply -f -

  # The manifest above creates $WORKLOADS_NAMESPACE, so the pull secret can go
  # in now. Nex builds workload pods without imagePullSecrets and runs them as
  # the namespace's default ServiceAccount, so attaching the secret to that
  # account is what lets private connector images pull.
  create_pull_secret "$WORKLOADS_NAMESPACE"
  kubectl --context "$KCTX" --namespace "$WORKLOADS_NAMESPACE" \
    patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"synadia-registry"}]}' >/dev/null
  bold "\nAttached the registry pull secret to the default ServiceAccount in ${WORKLOADS_NAMESPACE}\n"

  kc rollout status deployment/nex --timeout=5m

  # Nex reports "nex node ready" even when credential minting failed and it
  # registered no agents, so the rollout succeeding is not proof it works.
  # Nex only mints credentials at startup and gives up after 5 tries in about 5
  # seconds, so a node that loses the race stays broken until it restarts.
  # Check the logs and restart until the agents appear.
  check_nex_agents() {
    local logs
    logs=$(kc logs deployment/nex --tail=-1 2>/dev/null)
    if echo "$logs" | grep -q 'without any agents'; then
      return 1
    fi
    echo "$logs" | grep -q 'agent registered'
  }

  local nex_attempts=4
  local attempt=1
  sleep 8
  while ! check_nex_agents; do
    if [ "$attempt" -ge "$nex_attempts" ]; then
      red "Nex is running but registered no agents after ${nex_attempts} attempts." >&2
      red "Check $(bold 'kubectl -n '"$NAMESPACE"' logs deployment/nex')" >&2
      exit 1
    fi
    bold "\nNex started without agents, restarting it (${attempt}/${nex_attempts})...\n"
    kc rollout restart deployment/nex >/dev/null
    kc rollout status deployment/nex --timeout=5m
    sleep 8
    attempt=$(( attempt + 1 ))
  done

  # Both Kubernetes nexlets currently register under the same agent name, so
  # only one of them survives and which one wins changes between restarts.
  # Report what actually registered rather than assuming both did.
  bold '\nNex node started, agents registered:\n'
  kc logs deployment/nex --tail=-1 2>/dev/null \
    | grep 'agent registered' | sed 's/^/  /' || true
}

start_nex

cat <<EOF
Done bootstrapping Synadia Platform on Kubernetes, open the UI at $(link 'http://localhost:8080') and login with:

    username: $(bold 'admin')
    password: $(bold "$ADMIN_PASSWORD")

Check out the HTTP Gateway API documentation at $(link 'http://localhost:8081/api/')

Stop the trial with $(bold './scripts/stop-k8s.sh')
EOF

if [ -n "$open" ]; then
  case "$(uname -s)" in
    Linux)  check_command xdg-open && xdg-open "http://localhost:8080" ;;
    Darwin) open "http://localhost:8080" ;;
  esac
fi
