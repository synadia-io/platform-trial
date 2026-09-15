# Synadia Platform Trial

This is the code repository for the [Synadia Platform Trial](https://docs.synadia.com/platform/trial). See the Trial link for
steps to run the trial.

Synadia Platform provides everything you love about NATS.io, packaged with enterprise-grade features. Managed by us or self-hosted.

The Synadia Platform Trial runs these platform components:

- [NATS](https://nats.io) - The core connective technology underlying the platform
- [Control Plane](control-plane): the unified interface (UI and API) for securing, managing, and monitoring NATS deployments
- [Connectors](/connect): production-ready bridges between NATS and MongoDB, Kafka, AWS, GCP, Azure (and more) - managed from Control Plane
- [Workloads](/workloads): NATS-native distributed compute, managed from Control Plane
- [HTTP Gateway](/platform/http-gateway): HTTP calls to NATS endpoints, for fetching data or triggering services

## Run the trial

The trial runs on Docker Compose or on a local Kubernetes cluster. Both put
Control Plane on http://localhost:8080 and the HTTP Gateway on
http://localhost:8081.

```sh
task start          # Docker Compose
task start:k8s      # Kubernetes (kind)
```

```sh
task stop           # Docker Compose
task stop:k8s       # Kubernetes (kind)
```

Pass flags after `--`, for example `task start:k8s -- --nex --open`.

### Kubernetes

`scripts/start-k8s.sh` creates a [kind](https://kind.sigs.k8s.io) cluster,
installs the platform Helm charts, and bootstraps the system through the
Control Plane API. It needs `kind`, `kubectl`, `helm` and `jq`, plus `nk` for
`--nex`.

Set your registry credentials first:

```sh
export SYNADIA_CR_USERNAME=<username>
export SYNADIA_CR_PASSWORD=<password>
```
